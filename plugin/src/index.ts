/**
 * CodeForge - OpenCode Plugin
 * 
 * Enables AI to publish code suggestions for hunk-by-hunk review.
 * Works with jj (Jujutsu) for version control.
 * 
 * The plugin exposes:
 * 1. Tools for the AI to call (publish_suggestion, suggestion_status, etc.)
 * 2. HTTP server for the editor to send feedback directly (POST /feedback, etc.)
 * 3. Events emitted via OpenCode's log API (suggestion.ready, suggestion.hunk_applied, etc.)
 */

import { tool, type Plugin } from "@opencode-ai/plugin";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
// Server type from Bun.serve()
import { SuggestionStore, generateSuggestionId } from "./suggestion-store.ts";
import { SuggestionEventEmitter } from "./event-emitter.ts";
import { parseDiff, fileDiffsToHunks, filterFileDiffs, type FilterOptions, calculateLineOffset, adjustHunkLineNumbers } from "./diff-parser.ts";
import { applyHunkToFile, applyModifiedHunk, reverseHunk } from "./patch-applier.ts";
import { createHttpServer } from "./http-server.ts";
import type { HunkFeedback, PublishSuggestionResult, FeedbackResult } from "./types.ts";

/**
 * CodeForge configuration schema
 * 
 * Config is loaded from (in order of precedence, later overrides earlier):
 * 1. Default values
 * 2. Global config: ~/.config/opencode/codeforge.json
 * 3. Project config: .opencode/codeforge.json
 * 4. Environment variables (highest precedence)
 */
export interface CodeForgeConfig {
  server?: {
    enabled?: boolean;
    port?: number;
    host?: string;
  };
}

/**
 * Load and merge configuration from all sources
 */
export function loadConfig(projectDir: string): { enabled: boolean; port: number; host: string } {
  // Defaults
  let enabled = true;
  let port = 4097;
  let host = "127.0.0.1";

  // Helper to load JSON config file
  const loadJsonConfig = (path: string): CodeForgeConfig | null => {
    try {
      if (existsSync(path)) {
        const content = readFileSync(path, "utf-8");
        return JSON.parse(content) as CodeForgeConfig;
      }
    } catch (error) {
      console.warn(`[codeforge] Failed to load config from ${path}:`, error);
    }
    return null;
  };

  // 1. Global config: ~/.config/opencode/codeforge.json
  const globalConfigPath = join(homedir(), ".config", "opencode", "codeforge.json");
  const globalConfig = loadJsonConfig(globalConfigPath);
  if (globalConfig?.server) {
    if (globalConfig.server.enabled !== undefined) enabled = globalConfig.server.enabled;
    if (globalConfig.server.port !== undefined) port = globalConfig.server.port;
    if (globalConfig.server.host !== undefined) host = globalConfig.server.host;
  }

  // 2. Project config: .opencode/codeforge.json
  const projectConfigPath = join(projectDir, ".opencode", "codeforge.json");
  const projectConfig = loadJsonConfig(projectConfigPath);
  if (projectConfig?.server) {
    if (projectConfig.server.enabled !== undefined) enabled = projectConfig.server.enabled;
    if (projectConfig.server.port !== undefined) port = projectConfig.server.port;
    if (projectConfig.server.host !== undefined) host = projectConfig.server.host;
  }

  // 3. Environment variables (highest precedence)
  if (process.env.CODEFORGE_SERVER_ENABLED !== undefined) {
    enabled = process.env.CODEFORGE_SERVER_ENABLED !== "false";
  }
  if (process.env.CODEFORGE_SERVER_PORT !== undefined) {
    const envPort = parseInt(process.env.CODEFORGE_SERVER_PORT, 10);
    if (!isNaN(envPort)) port = envPort;
  }
  if (process.env.CODEFORGE_SERVER_HOST !== undefined) {
    host = process.env.CODEFORGE_SERVER_HOST;
  }

  return { enabled, port, host };
}

// Global state (persists across tool calls within a session)
// Map of working directory -> store to support multiple projects
const stores = new Map<string, SuggestionStore>();
const emitters = new Map<string, SuggestionEventEmitter>();
let httpServer: ReturnType<typeof Bun.serve> | null = null;

/**
 * Get diff from jj for a specific change (in git/unified diff format)
 */
async function getJjDiff($: any, changeId?: string): Promise<string> {
  try {
    if (changeId) {
      const result = await $`jj diff -r ${changeId} --git`.text();
      return result;
    } else {
      const result = await $`jj diff --git`.text();
      return result;
    }
  } catch (error) {
    throw new Error(`Failed to get jj diff: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * Get current jj change ID
 */
async function getCurrentChangeId($: any): Promise<string> {
  try {
    console.log("[codeforge] Running: jj log -r @ --no-graph -T commit_id");
    const result = await $`jj log -r @ --no-graph -T commit_id`.text();
    console.log("[codeforge] Result:", result);
    console.log("[codeforge] Result length:", result.length);
    return result.trim();
  } catch (error) {
    console.error("[codeforge] Error:", error);
    throw new Error(`Failed to get current change ID: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * The main plugin export
 */
export const CodeForgePlugin: Plugin = async ({ client, directory, $ }) => {
  // Validate and normalize directory parameter
  let workingDir = directory;
  if (!directory || directory.trim() === "" || directory === "/") {
    // Use home directory as fallback
    workingDir = process.env.HOME || process.env.USERPROFILE || "/tmp";
    console.warn(`[codeforge] Invalid working directory "${directory}", using fallback: ${workingDir}`);
  }

  // Set the shell working directory to the project directory
  const shell = $.cwd(workingDir);

  // Load configuration from files and environment
  const config = loadConfig(workingDir);
  
  // Initialize or get existing store for this working directory
  let store = stores.get(workingDir);
  if (!store) {
    try {
      store = new SuggestionStore({
        dbPath: `${workingDir}/.opencode/codeforge.db`,
        feedbackLogPath: `${workingDir}/.opencode/suggestion-feedback.jsonl`,
      });
      stores.set(workingDir, store);
      console.log(`[codeforge] Database initialized for ${workingDir}`);
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      console.error(`[codeforge] Failed to initialize database:`, errorMsg);
      console.error(`[codeforge] Database path: ${workingDir}/.opencode/codeforge.db`);
      throw new Error(`Database initialization failed: ${errorMsg}. Working directory: ${workingDir}`);
    }
  } else {
    console.log(`[codeforge] Reusing existing database for ${workingDir}`);
  }
  
  // Initialize or get existing emitter for this working directory
  let emitter = emitters.get(workingDir);
  if (!emitter) {
    emitter = new SuggestionEventEmitter(client);
    emitters.set(workingDir, emitter);
  }

  // Start the HTTP server for direct editor communication (if enabled)
  if (config.enabled) {
    // Check if server is already running (plugin may be loaded multiple times)
    if (httpServer) {
      console.log(`[codeforge] HTTP server already running on ${config.host}:${config.port}`);
    } else {
      try {
        httpServer = createHttpServer(
          { port: config.port, host: config.host },
          { stores, emitters, client }
        );
        console.log(`[codeforge] HTTP server started on ${config.host}:${config.port}`);
      } catch (error) {
        const errorMsg = error instanceof Error ? error.message : String(error);
        
        // Check if it's a port-in-use error - this is common and not a real error
        if (errorMsg.includes("EADDRINUSE") || errorMsg.includes("address already in use") || errorMsg.includes("Is port")) {
          console.log(`[codeforge] Port ${config.port} is already in use. HTTP server not started.`);
          console.log(`[codeforge] Plugin will continue without HTTP server - editor integration will not work.`);
        } else {
          // Other errors are more serious, log as error
          console.error(`[codeforge] Failed to start HTTP server on port ${config.port}: ${errorMsg}`);
        }
        
        // Don't throw - allow plugin to load without HTTP server
        // Tools will still work, just no editor communication
        httpServer = null;
      }
    }
  } else {
    console.log("[codeforge] HTTP server disabled via config");
    httpServer = null;
  }

  return {
    tool: {
      /**
       * Publish current jj change as a suggestion for user review
       */
      publish_suggestion: tool({
        description: "Publish current jj change as a suggestion for user review. Call this when you have made changes and want the user to review them hunk-by-hunk. Supports selective publishing by filtering files or line ranges.",
        args: {
          description: tool.schema.string().describe("Human-readable description of the changes"),
          change_id: tool.schema.string().optional().describe("jj change ID to publish (defaults to current change)"),
          files: tool.schema.array(tool.schema.string()).optional().describe("File paths or glob patterns to include (e.g., ['src/**/*.ts', 'lib/utils.ts']). If omitted, includes all changed files."),
          exclude_files: tool.schema.array(tool.schema.string()).optional().describe("File paths or glob patterns to exclude (e.g., ['**/*.test.ts', 'docs/**'])"),
          line_ranges: tool.schema.array(
            tool.schema.object({
              file: tool.schema.string().describe("File path to apply line range filter"),
              start_line: tool.schema.number().describe("Start line number (inclusive)"),
              end_line: tool.schema.number().describe("End line number (inclusive)"),
            })
          ).optional().describe("Filter hunks to only include those overlapping with specified line ranges"),
          hunk_descriptions: tool.schema.record(tool.schema.string(), tool.schema.string()).optional().describe("Map of hunk IDs to short one-line descriptions. If provided, these will be shown in the editor instead of hunk IDs. Format: {\"suggestion-id:file:0\": \"Add error handling\", \"suggestion-id:file:1\": \"Fix typo\"}"),
        },
        async execute(args): Promise<string> {
          try {
            // Check database health
            if (!store.isDbHealthy()) {
              return JSON.stringify({
                success: false,
                error: `Database is not accessible. Path: ${store.getDbPath()}`,
              });
            }

            // Get the change ID
            const changeId = args.change_id ?? await getCurrentChangeId(shell);

            // Get the diff
            const diffText = await getJjDiff(shell, changeId);

            if (!diffText.trim()) {
              return JSON.stringify({
                success: false,
                error: "No changes to publish",
              });
            }

            // Parse the diff into file diffs
            let fileDiffs = parseDiff(diffText);
            
            // Always exclude .opencode directory files
            const defaultExcludeFiles = [".opencode/**"];
            const excludeFiles = args.exclude_files 
              ? [...defaultExcludeFiles, ...args.exclude_files]
              : defaultExcludeFiles;
            
            // Apply filters (always apply default exclude)
            const hasFilters = args.files || args.exclude_files || args.line_ranges;
            const filterOptions: FilterOptions = {
              includeFiles: args.files,
              excludeFiles,
              lineRanges: args.line_ranges?.map(r => ({
                file: r.file,
                startLine: r.start_line,
                endLine: r.end_line,
              })),
            };
            fileDiffs = filterFileDiffs(fileDiffs, filterOptions);
            
            // Convert to hunks
            const suggestionId = generateSuggestionId();
            let hunks = fileDiffsToHunks(fileDiffs, suggestionId);
            const files = [...new Set(fileDiffs.map(fd => fd.newPath !== "/dev/null" ? fd.newPath : fd.oldPath))];
            
            if (hunks.length === 0) {
              const filterMsg = hasFilters ? " (after applying filters)" : "";
              return JSON.stringify({
                success: false,
                error: `No hunks found in diff${filterMsg}`,
              });
            }

            // Apply custom hunk descriptions if provided
            if (args.hunk_descriptions) {
              hunks = hunks.map(hunk => ({
                ...hunk,
                description: args.hunk_descriptions![hunk.id] || hunk.description,
              }));
            }

            // Create the suggestion with relative working directory (relative to home)
            const homeDir = process.env.HOME || process.env.USERPROFILE || "";
            const relativeWorkingDir = workingDir.startsWith(homeDir) 
              ? workingDir.slice(homeDir.length + 1)  // +1 for the slash
              : workingDir;
            
            const suggestion = store.createSuggestion({
              id: suggestionId,
              jjChangeId: changeId,
              description: args.description,
              files,
              hunks,
              workingDirectory: relativeWorkingDir,
            });

            // Emit the ready event
            await emitter.emitReady(suggestion);

            const result: PublishSuggestionResult = {
              suggestionId,
              hunkCount: hunks.length,
              files,
            };

            const filterInfo = hasFilters ? " (filtered)" : "";
            return JSON.stringify({
              success: true,
              ...result,
              message: `Published suggestion with ${hunks.length} hunks in ${files.length} files${filterInfo}`,
            });
          } catch (error) {
            const errorMessage = error instanceof Error ? error.message : String(error);
            await emitter.emitError("jj_error", errorMessage);
            return JSON.stringify({
              success: false,
              error: errorMessage,
            });
          }
        },
      }),

      /**
       * Submit feedback for a suggestion hunk
       */
      suggestion_feedback: tool({
        description: "Submit feedback for a suggestion hunk. Called by the editor when user reviews a hunk.",
        args: {
          suggestion_id: tool.schema.string().describe("The suggestion ID"),
          hunk_id: tool.schema.string().describe("The hunk ID within the suggestion"),
          action: tool.schema.enum(["accept", "reject", "modify"]).describe("The action to take"),
          modified_diff: tool.schema.string().optional().describe("If action is 'modify', the user's edited diff"),
          comment: tool.schema.string().optional().describe("Optional feedback comment"),
        },
        async execute(args): Promise<string> {
          try {
            // Check database health
            if (!store.isDbHealthy()) {
              return JSON.stringify({
                success: false,
                error: `Database is not accessible. Path: ${store.getDbPath()}`,
                applied: false,
              });
            }

            const suggestion = store.getSuggestion(args.suggestion_id);
            if (!suggestion) {
              return JSON.stringify({
                success: false,
                error: `Suggestion not found: ${args.suggestion_id}`,
              });
            }

            const hunk = store.getHunk(args.suggestion_id, args.hunk_id);
            if (!hunk) {
              return JSON.stringify({
                success: false,
                error: `Hunk not found: ${args.hunk_id}`,
              });
            }

            const feedback: HunkFeedback = {
              suggestionId: args.suggestion_id,
              hunkId: args.hunk_id,
              action: args.action,
              modifiedDiff: args.modified_diff,
              comment: args.comment,
            };

            let applied = false;
            let reverted = false;

            const filePath = `${workingDir}/${hunk.file}`;

            // Calculate line offset based on previously applied hunks in this file
            const fileHunks = suggestion.hunks.filter(h => h.file === hunk.file);
            const appliedHunkIds = new Set<string>();
            for (const [hunkId, state] of suggestion.hunkStates) {
              if (state.reviewed && state.applied) {
                appliedHunkIds.add(hunkId);
              }
            }
            
            // Parse all hunks to get their metadata
            const fileDiffs = parseDiff(`diff --git a/${hunk.file} b/${hunk.file}\n` + 
              fileHunks.map(h => h.diff).join("\n"));
            const parsedHunks = fileDiffs[0]?.hunks || [];
            
            // Calculate the line offset for this hunk
            const lineOffset = calculateLineOffset(parsedHunks, appliedHunkIds, hunk.file, args.suggestion_id);
            
            // Adjust the hunk diff if there's an offset
            let adjustedDiff = hunk.diff;
            if (lineOffset !== 0) {
              adjustedDiff = adjustHunkLineNumbers(hunk.diff, lineOffset);
            }

            if (args.action === "accept") {
              // Accept: hunk is already in working copy, nothing to do
              // (AI made the change, user approved it)
              applied = true;
            } else if (args.action === "modify") {
              // Modify: revert original, apply modified version
              const revertResult = await applyHunkToFile(filePath, reverseHunk(adjustedDiff));
              if (!revertResult.success) {
                await emitter.emitError(
                  "apply_failed",
                  revertResult.error ?? "Failed to revert hunk for modification",
                  args.suggestion_id,
                  args.hunk_id
                );
                return JSON.stringify({
                  success: false,
                  error: revertResult.error,
                  applied: false,
                });
              }

              const applyResult = await applyModifiedHunk(filePath, args.modified_diff!);
              if (!applyResult.success) {
                await emitter.emitError(
                  "apply_failed",
                  applyResult.error ?? "Failed to apply modified hunk",
                  args.suggestion_id,
                  args.hunk_id
                );
                return JSON.stringify({
                  success: false,
                  error: applyResult.error,
                  applied: false,
                });
              }

              applied = true;
            } else if (args.action === "reject") {
              // Reject: revert the hunk (undo the AI's change)
              const revertResult = await applyHunkToFile(filePath, reverseHunk(adjustedDiff));
              if (!revertResult.success) {
                await emitter.emitError(
                  "apply_failed",
                  revertResult.error ?? "Failed to revert rejected hunk",
                  args.suggestion_id,
                  args.hunk_id
                );
                return JSON.stringify({
                  success: false,
                  error: revertResult.error,
                  applied: false,
                });
              }

              reverted = true;
            }

            // Update the store
            store.updateHunkState(args.suggestion_id, args.hunk_id, feedback, applied || reverted);

            // Emit the hunk applied event
            const action = args.action === "accept" ? "accepted"
              : args.action === "reject" ? "rejected"
              : "modified";
            await emitter.emitHunkApplied(args.suggestion_id, args.hunk_id, action);

            // Emit status update
            const remaining = store.getRemainingCount(args.suggestion_id);
            await emitter.emitStatus(
              remaining === 0 ? "applied" : "partial",
              `${remaining} hunks remaining`,
              args.suggestion_id
            );

            const result: FeedbackResult = {
              success: true,
              applied,
              reverted,
              remainingHunks: remaining,
            };

            return JSON.stringify(result);
          } catch (error) {
            const errorMessage = error instanceof Error ? error.message : String(error);
            await emitter.emitError("unknown", errorMessage, args.suggestion_id, args.hunk_id);
            return JSON.stringify({
              success: false,
              error: errorMessage,
              applied: false,
            });
          }
        },
      }),

      /**
       * Send a status update to the user
       */
      suggestion_status: tool({
        description: "Send a status update to the user. Use this to keep the user informed of progress while working on changes.",
        args: {
          message: tool.schema.string().describe("One-line status message"),
          suggestion_id: tool.schema.string().optional().describe("Related suggestion ID if applicable"),
        },
        async execute(args): Promise<string> {
          try {
            await emitter.emitStatus("working", args.message, args.suggestion_id);
            return JSON.stringify({ success: true, sent: true });
          } catch (error) {
            return JSON.stringify({
              success: false,
              error: error instanceof Error ? error.message : String(error),
            });
          }
        },
      }),

      /**
       * List all pending suggestions
       */
      list_suggestions: tool({
        description: "List all pending suggestions with their review status",
        args: {},
        async execute(): Promise<string> {
          try {
            // Check database health
            if (!store.isDbHealthy()) {
              return JSON.stringify({
                success: false,
                error: `Database is not accessible. Path: ${store.getDbPath()}`,
              });
            }

            const result = store.listSuggestions(workingDir);
            
            // Also emit the list event for the editor
            await emitter.emitList(result.suggestions);

            return JSON.stringify({
              success: true,
              ...result,
            });
          } catch (error) {
            return JSON.stringify({
              success: false,
              error: error instanceof Error ? error.message : String(error),
            });
          }
        },
      }),

      /**
       * Finalize or discard a suggestion
       */
      complete_suggestion: tool({
        description: "Finalize or discard a suggestion. Use 'finalize' after all hunks are reviewed to sync changes, or 'discard' to abandon the suggestion.",
        args: {
          suggestion_id: tool.schema.string().describe("The suggestion ID"),
          action: tool.schema.enum(["finalize", "discard"]).describe("'finalize' to sync changes, 'discard' to abandon"),
        },
        async execute(args): Promise<string> {
          try {
            // Check database health
            if (!store.isDbHealthy()) {
              return JSON.stringify({
                success: false,
                error: `Database is not accessible. Path: ${store.getDbPath()}`,
              });
            }

            const suggestion = store.getSuggestion(args.suggestion_id);
            if (!suggestion) {
              return JSON.stringify({
                success: false,
                error: `Suggestion not found: ${args.suggestion_id}`,
              });
            }

            if (args.action === "finalize") {
              // Sync with shared repo
              try {
                await shell`jj git push`.text();
                await emitter.emitStatus("applied", "Changes synced to remote", args.suggestion_id);
              } catch (error) {
                await emitter.emitError(
                  "sync_failed",
                  `Failed to sync: ${error instanceof Error ? error.message : String(error)}`,
                  args.suggestion_id
                );
                return JSON.stringify({
                  success: false,
                  error: "Failed to sync changes to remote",
                });
              }

              store.removeSuggestion(args.suggestion_id);
              return JSON.stringify({
                success: true,
                action: "finalized",
                message: "Suggestion finalized and synced",
              });
            } else {
              // Discard
              store.discardSuggestion(args.suggestion_id);
              store.removeSuggestion(args.suggestion_id);
              
              await emitter.emitStatus("applied", "Suggestion discarded", args.suggestion_id);

              return JSON.stringify({
                success: true,
                action: "discarded",
                message: "Suggestion discarded",
              });
            }
          } catch (error) {
            return JSON.stringify({
              success: false,
              error: error instanceof Error ? error.message : String(error),
            });
          }
        },
      }),

      /**
       * Get details of a specific suggestion
       */
      get_suggestion: tool({
        description: "Get details of a specific suggestion including all hunks",
        args: {
          suggestion_id: tool.schema.string().describe("The suggestion ID"),
        },
        async execute(args): Promise<string> {
          try {
            // Check database health
            if (!store.isDbHealthy()) {
              return JSON.stringify({
                success: false,
                error: `Database is not accessible. Path: ${store.getDbPath()}`,
              });
            }

            const suggestion = store.getSuggestion(args.suggestion_id);
            if (!suggestion) {
              return JSON.stringify({
                success: false,
                error: `Suggestion not found: ${args.suggestion_id}`,
              });
            }

            // Convert Map to object for JSON serialization
            const hunkStates: Record<string, unknown> = {};
            for (const [key, value] of suggestion.hunkStates) {
              hunkStates[key] = value;
            }

            // Adjust hunk line numbers based on previously applied hunks
            const adjustedHunks = [...suggestion.hunks];
            const appliedHunkIds = new Set<string>();
            for (const [hunkId, state] of suggestion.hunkStates) {
              if (state.reviewed && state.applied) {
                appliedHunkIds.add(hunkId);
              }
            }

            // Group hunks by file and adjust line numbers
            const files = new Set(suggestion.hunks.map(h => h.file));
            for (const file of files) {
              const fileHunks = suggestion.hunks.filter(h => h.file === file);
              
              // Parse all hunks to get their metadata
              const fileDiffs = parseDiff(`diff --git a/${file} b/${file}\n` + 
                fileHunks.map(h => h.diff).join("\n"));
              const parsedHunks = fileDiffs[0]?.hunks || [];
              
              // Adjust each hunk's line numbers
              for (let i = 0; i < fileHunks.length; i++) {
                const hunk = fileHunks[i]!;
                const hunkId = hunk.id;
                
                // Calculate line offset for this hunk
                const lineOffset = calculateLineOffset(parsedHunks, appliedHunkIds, file, args.suggestion_id);
                
                // Adjust the hunk diff if there's an offset
                if (lineOffset !== 0) {
                  const adjustedDiff = adjustHunkLineNumbers(hunk.diff, lineOffset);
                  // Update the hunk in the adjustedHunks array
                  const adjustedIndex = adjustedHunks.findIndex(h => h.id === hunkId);
                  if (adjustedIndex !== -1) {
                    adjustedHunks[adjustedIndex] = {
                      ...adjustedHunks[adjustedIndex]!,
                      diff: adjustedDiff,
                    };
                  }
                }
              }
            }

            return JSON.stringify({
              success: true,
              suggestion: {
                id: suggestion.id,
                jjChangeId: suggestion.jjChangeId,
                description: suggestion.description,
                files: suggestion.files,
                hunks: adjustedHunks,
                status: suggestion.status,
                createdAt: suggestion.createdAt,
                hunkStates,
                remainingCount: store.getRemainingCount(args.suggestion_id),
              },
            });
          } catch (error) {
            return JSON.stringify({
              success: false,
              error: error instanceof Error ? error.message : String(error),
            });
          }
        },
      }),
    },

    // Cleanup function called when plugin is unloaded
    cleanup: async () => {
      if (httpServer) {
        httpServer.stop();
        httpServer = null;
        console.log("[codeforge] HTTP server stopped");
      }
      if (store) {
        store.close();
        console.log("[codeforge] Database connection closed");
      }
    },
  };
};

// Default export for OpenCode plugin loading
export default CodeForgePlugin;
