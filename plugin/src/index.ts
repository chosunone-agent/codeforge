/**
 * Suggestion Manager - OpenCode Plugin
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
// Server type from Bun.serve()
import { SuggestionStore, generateSuggestionId } from "./suggestion-store.ts";
import { SuggestionEventEmitter } from "./event-emitter.ts";
import { parseDiff, fileDiffsToHunks, getFilesFromDiff } from "./diff-parser.ts";
import { applyHunkToFile, applyModifiedHunk, reverseHunk } from "./patch-applier.ts";
import { createHttpServer } from "./http-server.ts";
import type { HunkFeedback, PublishSuggestionResult, FeedbackResult } from "./types.ts";

// Configuration
const HTTP_SERVER_PORT = parseInt(process.env.SUGGESTION_MANAGER_PORT ?? "4097", 10);
const HTTP_SERVER_HOST = process.env.SUGGESTION_MANAGER_HOST ?? "127.0.0.1";

// Global state (persists across tool calls within a session)
let store: SuggestionStore;
let emitter: SuggestionEventEmitter;
let workingDirectory: string;
let httpServer: ReturnType<typeof Bun.serve> | null = null;

/**
 * Get diff from jj for a specific change (in git/unified diff format)
 */
async function getJjDiff($: any, changeId?: string): Promise<string> {
  try {
    const args = changeId ? ["-r", changeId, "--git"] : ["--git"];
    const result = await $`jj diff ${args}`.text();
    return result;
  } catch (error) {
    throw new Error(`Failed to get jj diff: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * Get current jj change ID
 */
async function getCurrentChangeId($: any): Promise<string> {
  try {
    const result = await $`jj log -r @ --no-graph -T 'change_id'`.text();
    return result.trim();
  } catch (error) {
    throw new Error(`Failed to get current change ID: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * The main plugin export
 */
export const SuggestionManagerPlugin: Plugin = async ({ client, directory, $ }) => {
  // Initialize global state
  store = new SuggestionStore({
    feedbackLogPath: `${directory}/.opencode/suggestion-feedback.jsonl`,
  });
  emitter = new SuggestionEventEmitter(client);
  workingDirectory = directory;

  // Start the HTTP server for direct editor communication
  httpServer = createHttpServer(
    { port: HTTP_SERVER_PORT, host: HTTP_SERVER_HOST },
    { store, emitter, workingDirectory, client }
  );

  return {
    tool: {
      /**
       * Publish current jj change as a suggestion for user review
       */
      publish_suggestion: tool({
        description: "Publish current jj change as a suggestion for user review. Call this when you have made changes and want the user to review them hunk-by-hunk.",
        args: {
          description: tool.schema.string().describe("Human-readable description of the changes"),
          change_id: tool.schema.string().optional().describe("jj change ID to publish (defaults to current change)"),
        },
        async execute(args): Promise<string> {
          try {
            // Get the change ID
            const changeId = args.change_id ?? await getCurrentChangeId($);

            // Get the diff
            const diffText = await getJjDiff($, changeId);

            if (!diffText.trim()) {
              return JSON.stringify({
                success: false,
                error: "No changes to publish",
              });
            }

            // Parse the diff into hunks
            const fileDiffs = parseDiff(diffText);
            const suggestionId = generateSuggestionId();
            const hunks = fileDiffsToHunks(fileDiffs, suggestionId);
            const files = getFilesFromDiff(diffText);

            if (hunks.length === 0) {
              return JSON.stringify({
                success: false,
                error: "No hunks found in diff",
              });
            }

            // Create the suggestion
            const suggestion = store.createSuggestion({
              id: suggestionId,
              jjChangeId: changeId,
              description: args.description,
              files,
              hunks,
            });

            // Emit the ready event
            await emitter.emitReady(suggestion);

            const result: PublishSuggestionResult = {
              suggestionId,
              hunkCount: hunks.length,
              files,
            };

            return JSON.stringify({
              success: true,
              ...result,
              message: `Published suggestion with ${hunks.length} hunks in ${files.length} files`,
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

            const filePath = `${workingDirectory}/${hunk.file}`;

            if (args.action === "accept") {
              // Accept: hunk is already in working copy, nothing to do
              // (AI made the change, user approved it)
              applied = true;
            } else if (args.action === "modify") {
              // Modify: revert original, apply modified version
              const revertResult = await applyHunkToFile(filePath, reverseHunk(hunk.diff));
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
              const revertResult = await applyHunkToFile(filePath, reverseHunk(hunk.diff));
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
            const reviewed = store.getReviewedCount(args.suggestion_id);
            const total = suggestion.hunks.length;
            await emitter.emitStatus(
              remaining === 0 ? "applied" : "partial",
              `${reviewed}/${total} hunks reviewed`,
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
            const result = store.listSuggestions();
            
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
                await $`jj git push`.text();
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

            return JSON.stringify({
              success: true,
              suggestion: {
                id: suggestion.id,
                jjChangeId: suggestion.jjChangeId,
                description: suggestion.description,
                files: suggestion.files,
                hunks: suggestion.hunks,
                status: suggestion.status,
                createdAt: suggestion.createdAt,
                hunkStates,
                reviewedCount: store.getReviewedCount(args.suggestion_id),
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
        console.log("[suggestion-manager] HTTP server stopped");
      }
    },
  };
};

// Default export for OpenCode plugin loading
export default SuggestionManagerPlugin;
