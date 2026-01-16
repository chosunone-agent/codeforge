/**
 * HTTP + WebSocket Server for Suggestion Manager
 * 
 * Exposes:
 * - HTTP endpoints for simple requests (health, list, etc.)
 * - WebSocket for bidirectional real-time communication
 * 
 * WebSocket Protocol:
 * 
 * Client -> Server:
 *   {"type": "feedback", "suggestionId": "...", "hunkId": "...", "action": "accept|reject|modify", "modifiedDiff"?: "...", "comment"?: "...", "workingDirectory": "..."}
 *   {"type": "complete", "suggestionId": "...", "action": "finalize|discard", "workingDirectory": "..."}
 *   {"type": "list", "workingDirectory": "..."}
 *   {"type": "get", "suggestionId": "...", "workingDirectory": "..."}
 * 
 * Server -> Client:
 *   {"type": "suggestion.ready", "suggestion": {...}}
 *   {"type": "suggestion.hunk_applied", "suggestionId": "...", "hunkId": "...", "action": "accepted|rejected|modified"}
 *   {"type": "suggestion.status", "status": "...", "message": "...", "suggestionId"?: "..."}
 *   {"type": "suggestion.error", "code": "...", "message": "...", "suggestionId"?: "...", "hunkId"?: "..."}
 *   {"type": "suggestion.list", "suggestions": [...]}
 *   {"type": "response", "id": "...", "success": true|false, "data"?: {...}, "error"?: "..."}
 */

import type { ServerWebSocket } from "bun";
import type { createOpencodeClient } from "@opencode-ai/sdk";
import { SuggestionStore } from "./suggestion-store.ts";
import { SuggestionEventEmitter } from "./event-emitter.ts";
import type { HunkFeedback, SuggestionComplete, FeedbackResult } from "./types.ts";

type OpencodeClient = ReturnType<typeof createOpencodeClient>;

export interface HttpServerConfig {
  port: number;
  host?: string;
}

export interface HttpServerDeps {
  stores: Map<string, SuggestionStore>;
  emitters: Map<string, SuggestionEventEmitter>;
  client: OpencodeClient;
}

// WebSocket client data
interface WSClientData {
  id: string;
  workingDirectory?: string;
}

// Connected WebSocket clients
const wsClients = new Set<ServerWebSocket<WSClientData>>();

/**
 * Broadcast a message to all connected WebSocket clients
 * If workingDirectory is specified, only send to clients subscribed to that directory
 */
export function broadcast(message: object, workingDirectory?: string): void {
  const data = JSON.stringify(message);
  for (const client of wsClients) {
    try {
      // If workingDirectory filter is specified, only send to matching clients
      if (workingDirectory) {
        // Normalize both for comparison
        const normalizedFilter = workingDirectory.replace(/\/+$/, "");
        const normalizedClient = (client.data.workingDirectory || "").replace(/\/+$/, "");
        if (normalizedClient === normalizedFilter) {
          client.send(data);
        }
      } else {
        // No filter, send to all
        client.send(data);
      }
    } catch {
      // Client disconnected, will be cleaned up
    }
  }
}

/**
 * Create and start the HTTP + WebSocket server
 */
export function createHttpServer(
  config: HttpServerConfig,
  deps: HttpServerDeps
): ReturnType<typeof Bun.serve> {
  const { stores, emitters, client } = deps;

  /**
   * Normalize a working directory path
   * Converts relative paths to absolute paths and normalizes them
   */
  function normalizeWorkingDirectory(workingDir: string): string {
    if (!workingDir || workingDir.trim() === "") {
      return process.env.HOME || process.env.USERPROFILE || "/tmp";
    }

    // If it's already absolute, return it normalized
    if (workingDir.startsWith("/")) {
      return workingDir.replace(/\/+$/, ""); // Remove trailing slashes
    }

    // It's relative, convert to absolute
    const homeDir = process.env.HOME || process.env.USERPROFILE || "";
    const absolutePath = `${homeDir}/${workingDir}`.replace(/\/+$/, "");
    return absolutePath;
  }

  /**
   * Get store and emitter for a working directory
   * Creates a new store if one doesn't exist
   */
  function getStoreAndEmitter(workingDirectory: string): { store: SuggestionStore; emitter: SuggestionEventEmitter } | null {
    const normalized = normalizeWorkingDirectory(workingDirectory);
    let store = stores.get(normalized);
    let emitter = emitters.get(normalized);
    
    if (!store || !emitter) {
      // Check if database file exists
      const fs = require("fs");
      const dbPath = `${normalized}/.opencode/codeforge.db`;
      const dbExists = fs.existsSync(dbPath);
      
      console.log(`[HTTP Server] Store not found for working directory: ${workingDirectory} (normalized: ${normalized})`);
      console.log(`[HTTP Server] Available stores:`, Array.from(stores.keys()));
      console.log(`[HTTP Server] Database file exists: ${dbExists ? "Yes" : "No"} (${dbPath})`);
      
      // Auto-create store for this directory
      try {
        console.log(`[HTTP Server] ${dbExists ? "Loading existing" : "Creating new"} store for: ${normalized}`);
        store = new SuggestionStore({
          dbPath: dbPath,
          feedbackLogPath: `${normalized}/.opencode/suggestion-feedback.jsonl`,
        });
        emitter = new SuggestionEventEmitter(client);
        
        stores.set(normalized, store);
        emitters.set(normalized, emitter);
        
        console.log(`[HTTP Server] Successfully ${dbExists ? "loaded existing" : "created new"} store for: ${normalized}`);
      } catch (error) {
        const errorMsg = error instanceof Error ? error.message : String(error);
        console.error(`[HTTP Server] Failed to ${dbExists ? "load existing" : "create"} store for ${normalized}:`, errorMsg);
        return null;
      }
    }
    
    return { store, emitter };
  }

  /**
   * Notify the AI about feedback by injecting a message into the current session
   */
  async function notifyAI(message: string): Promise<void> {
    try {
      const sessions = await client.session.list();
      if (!sessions.data || sessions.data.length === 0) {
        return;
      }
      
      // Find the main session (not a subagent) - subagent titles contain "@"
      // Also prefer sessions without a parentID (top-level sessions)
      const mainSession = sessions.data.find(s => 
        s.title && !s.title.includes("@") && !s.parentID
      ) || sessions.data.find(s => 
        s.title && !s.title.includes("@")
      ) || sessions.data[sessions.data.length - 1]; // fallback to oldest
      
      if (!mainSession?.id) {
        return;
      }

      // Inject message into the conversation
      await client.session.prompt({
        path: { id: mainSession.id },
        body: {
          noReply: true,
          parts: [{ type: "text", text: message }],
        },
      });
      
      // Also show a toast notification
      await client.tui.showToast({
        body: { message, variant: "info" },
      });
    } catch {
      // Silently fail - notification is best-effort
    }
  }

  /**
   * Process feedback (shared between HTTP and WebSocket)
   * 
   * NOTE: File modifications are handled client-side (in Neovim).
   * The server only tracks state and notifies the AI.
   * This avoids sync issues between server's jj working copy and client's local files.
   */
  async function processFeedback(body: HunkFeedback & { workingDirectory: string }): Promise<FeedbackResult & { error?: string }> {
    try {
      const result = getStoreAndEmitter(body.workingDirectory);
      if (!result) {
        return { success: false, applied: false, remainingHunks: 0, error: `No store found for working directory: ${body.workingDirectory}` };
      }

      const { store, emitter } = result;

      // Check database health
      if (!store.isDbHealthy()) {
        return { success: false, applied: false, remainingHunks: 0, error: `Database is not accessible. Path: ${store.getDbPath()}` };
      }

      const suggestion = store.getSuggestion(body.suggestionId);
      if (!suggestion) {
        return { success: false, applied: false, remainingHunks: 0, error: `Suggestion not found: ${body.suggestionId}` };
      }

      const hunk = store.getHunk(body.suggestionId, body.hunkId);
      if (!hunk) {
        return { success: false, applied: false, remainingHunks: 0, error: `Hunk not found: ${body.hunkId}` };
      }

      // Determine the result based on action
      // Note: actual file changes are applied client-side, we just track state here
      const applied = body.action === "accept" || body.action === "modify";
      const reverted = body.action === "reject";

      // Update the store
      store.updateHunkState(body.suggestionId, body.hunkId, body, applied || reverted);

      // Emit events (these will be broadcast to WebSocket clients)
      const action = body.action === "accept" ? "accepted" : body.action === "reject" ? "rejected" : "modified";
      await emitter.emitHunkApplied(body.suggestionId, body.hunkId, action);

      const remaining = store.getRemainingCount(body.suggestionId);
      await emitter.emitStatus(remaining === 0 ? "applied" : "partial", `${remaining} hunks remaining`, body.suggestionId);

      // Notify the AI
      const actionVerb = body.action === "accept" ? "accepted" : body.action === "reject" ? "rejected" : "modified";
      const commentPart = body.comment ? ` Comment: "${body.comment}"` : "";
      const modifyInfo = body.action === "modify" && body.modifiedDiff ? `\nModified diff:\n${body.modifiedDiff}` : "";
      await notifyAI(`[Suggestion Feedback] User ${actionVerb} hunk in ${hunk.file}. ${remaining} hunks remaining.${commentPart}${modifyInfo}`);

      return { success: true, applied, reverted, remainingHunks: remaining };
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      console.error(`[HTTP Server] Error processing feedback:`, errorMsg);
      return { success: false, applied: false, remainingHunks: 0, error: `Database error: ${errorMsg}` };
    }
  }

  /**
   * Process complete request (shared between HTTP and WebSocket)
   */
  async function processComplete(body: SuggestionComplete & { workingDirectory: string }): Promise<{ success: boolean; action?: string; error?: string }> {
    try {
      const result = getStoreAndEmitter(body.workingDirectory);
      if (!result) {
        return { success: false, error: `No store found for working directory: ${body.workingDirectory}` };
      }

      const { store, emitter } = result;

      // Check database health
      if (!store.isDbHealthy()) {
        return { success: false, error: `Database is not accessible. Path: ${store.getDbPath()}` };
      }

      const suggestion = store.getSuggestion(body.suggestionId);
      if (!suggestion) {
        return { success: false, error: `Suggestion not found: ${body.suggestionId}` };
      }

      if (body.action === "finalize") {
        await emitter.emitStatus("applied", "Suggestion finalized", body.suggestionId);
        store.removeSuggestion(body.suggestionId);
        return { success: true, action: "finalized" };
      } else {
        store.discardSuggestion(body.suggestionId);
        store.removeSuggestion(body.suggestionId);
        await emitter.emitStatus("applied", "Suggestion discarded", body.suggestionId);
        return { success: true, action: "discarded" };
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      console.error(`[HTTP Server] Error processing complete:`, errorMsg);
      return { success: false, error: `Database error: ${errorMsg}` };
    }
  }

  /**
   * Handle WebSocket message
   */
  async function handleWSMessage(ws: ServerWebSocket<WSClientData>, message: string): Promise<void> {
    let parsed: { type: string; id?: string; [key: string]: unknown };
    
    try {
      parsed = JSON.parse(message);
    } catch {
      ws.send(JSON.stringify({ type: "error", error: "Invalid JSON" }));
      return;
    }

    const { type, id } = parsed;

    // Helper to send response
    const respond = (data: object) => {
      ws.send(JSON.stringify({ type: "response", id, ...data }));
    };

    try {
      switch (type) {
        case "feedback": {
          if (!parsed.suggestionId || !parsed.hunkId || !parsed.action || !parsed.workingDirectory) {
            respond({ success: false, error: "Missing required fields: suggestionId, hunkId, action, workingDirectory" });
            return;
          }
          if (!["accept", "reject", "modify"].includes(parsed.action as string)) {
            respond({ success: false, error: "Invalid action. Must be: accept, reject, or modify" });
            return;
          }
          const result = await processFeedback({
            suggestionId: parsed.suggestionId as string,
            hunkId: parsed.hunkId as string,
            action: parsed.action as "accept" | "reject" | "modify",
            modifiedDiff: parsed.modifiedDiff as string | undefined,
            comment: parsed.comment as string | undefined,
            workingDirectory: parsed.workingDirectory as string,
          });
          respond(result);
          break;
        }

        case "complete": {
          if (!parsed.suggestionId || !parsed.action || !parsed.workingDirectory) {
            respond({ success: false, error: "Missing required fields: suggestionId, action, workingDirectory" });
            return;
          }
          if (!["finalize", "discard"].includes(parsed.action as string)) {
            respond({ success: false, error: "Invalid action. Must be: finalize or discard" });
            return;
          }
          const result = await processComplete({
            suggestionId: parsed.suggestionId as string,
            action: parsed.action as "finalize" | "discard",
            workingDirectory: parsed.workingDirectory as string,
          });
          respond(result);
          break;
        }

        case "list": {
          try {
            if (!parsed.workingDirectory) {
              respond({ success: false, error: "Missing required field: workingDirectory" });
              return;
            }
            const storeResult = getStoreAndEmitter(parsed.workingDirectory as string);
            if (!storeResult) {
              respond({ success: false, error: `No store found for working directory: ${parsed.workingDirectory}` });
              return;
            }
            const { store } = storeResult;
            if (!store.isDbHealthy()) {
              respond({ success: false, error: `Database is not accessible. Path: ${store.getDbPath()}` });
              return;
            }
            // Use normalized working directory for filtering
            const normalizedWd = normalizeWorkingDirectory(parsed.workingDirectory as string);
            const listResult = store.listSuggestions(normalizedWd);
            respond({ success: true, ...listResult });
          } catch (error) {
            const errorMsg = error instanceof Error ? error.message : String(error);
            console.error(`[HTTP Server] Error listing suggestions (WebSocket):`, errorMsg);
            respond({ success: false, error: `Database error: ${errorMsg}` });
          }
          break;
        }

        case "subscribe": {
          // Client wants to subscribe to a specific working directory
          const wd = parsed.workingDirectory as string | undefined;
          ws.data.workingDirectory = wd;
          // Send filtered list
          const storeResult = getStoreAndEmitter(wd || "");
          if (!storeResult) {
            respond({ success: false, error: `No store found for working directory: ${wd}` });
            return;
          }
          const { store } = storeResult;
          // Use normalized working directory for filtering
          const normalizedWd = normalizeWorkingDirectory(wd || "");
          const listResult = store.listSuggestions(normalizedWd);
          respond({ success: true, subscribed: wd, ...listResult });
          break;
        }

        case "get": {
          try {
            if (!parsed.suggestionId || !parsed.workingDirectory) {
              respond({ success: false, error: "Missing required fields: suggestionId, workingDirectory" });
              return;
            }
            const storeResult = getStoreAndEmitter(parsed.workingDirectory as string);
            if (!storeResult) {
              respond({ success: false, error: `No store found for working directory: ${parsed.workingDirectory}` });
              return;
            }
            const { store } = storeResult;
            if (!store.isDbHealthy()) {
              respond({ success: false, error: `Database is not accessible. Path: ${store.getDbPath()}` });
              return;
            }
            const suggestion = store.getSuggestion(parsed.suggestionId as string);
            if (!suggestion) {
              respond({ success: false, error: `Suggestion not found: ${parsed.suggestionId}` });
              return;
            }
            // Convert Map to object
            const hunkStates: Record<string, unknown> = {};
            for (const [key, value] of suggestion.hunkStates) {
              hunkStates[key] = value;
            }
            respond({
              success: true,
              suggestion: {
                ...suggestion,
                hunkStates,
                remainingCount: store.getRemainingCount(parsed.suggestionId as string),
              },
            });
          } catch (error) {
            const errorMsg = error instanceof Error ? error.message : String(error);
            console.error(`[HTTP Server] Error getting suggestion (WebSocket):`, errorMsg);
            respond({ success: false, error: `Database error: ${errorMsg}` });
          }
          break;
        }

        default:
          respond({ success: false, error: `Unknown message type: ${type}` });
      }
    } catch (error) {
      respond({ success: false, error: error instanceof Error ? error.message : "Internal error" });
    }
  }

  const server = Bun.serve<WSClientData>({
    port: config.port,
    hostname: config.host ?? "127.0.0.1",

    async fetch(req, server) {
      const url = new URL(req.url);
      const path = url.pathname;
      const method = req.method;

      // WebSocket upgrade
      if (path === "/ws") {
        const clientId = crypto.randomUUID();
        const upgraded = server.upgrade(req, {
          data: { id: clientId },
        });
        if (upgraded) {
          return undefined;
        }
        return new Response("WebSocket upgrade failed", { status: 400 });
      }

      // CORS headers for local development
      const corsHeaders = {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
      };

      // Handle preflight
      if (method === "OPTIONS") {
        return new Response(null, { headers: corsHeaders });
      }

      try {
        // Health check
        if (path === "/health" && method === "GET") {
          const workingDir = url.searchParams.get("workingDirectory");
          if (!workingDir) {
            return Response.json(
              { error: "Missing required query parameter: workingDirectory" },
              { status: 400, headers: corsHeaders }
            );
          }
          const storeResult = getStoreAndEmitter(workingDir);
          if (!storeResult) {
            return Response.json(
              { error: `No store found for working directory: ${workingDir}` },
              { status: 404, headers: corsHeaders }
            );
          }
          const { store } = storeResult;
          const dbHealthy = store.isDbHealthy();
          const normalizedWd = normalizeWorkingDirectory(workingDir);
          return Response.json(
            { 
              healthy: dbHealthy, 
              service: "codeforge", 
              wsClients: wsClients.size,
              dbPath: store.getDbPath(),
              dbHealthy: dbHealthy,
              workingDirectory: workingDir,
              normalizedWorkingDirectory: normalizedWd
            },
            { headers: corsHeaders }
          );
        }

        // List suggestions
        if (path === "/suggestions" && method === "GET") {
          try {
            const workingDir = url.searchParams.get("workingDirectory");
            if (!workingDir) {
              return Response.json(
                { error: "Missing required query parameter: workingDirectory" },
                { status: 400, headers: corsHeaders }
              );
            }
            const storeResult = getStoreAndEmitter(workingDir);
            if (!storeResult) {
              return Response.json(
                { error: `No store found for working directory: ${workingDir}` },
                { status: 404, headers: corsHeaders }
              );
            }
            const { store } = storeResult;
            if (!store.isDbHealthy()) {
              return Response.json(
                { error: `Database is not accessible. Path: ${store.getDbPath()}` },
                { status: 503, headers: corsHeaders }
              );
            }
            // Use normalized working directory for filtering
            const normalizedWd = normalizeWorkingDirectory(workingDir);
            const result = store.listSuggestions(normalizedWd);
            return Response.json(result, { headers: corsHeaders });
          } catch (error) {
            const errorMsg = error instanceof Error ? error.message : String(error);
            console.error(`[HTTP Server] Error listing suggestions:`, errorMsg);
            return Response.json(
              { error: `Database error: ${errorMsg}` },
              { status: 503, headers: corsHeaders }
            );
          }
        }

        // Get specific suggestion
        if (path.startsWith("/suggestions/") && method === "GET") {
          try {
            const workingDir = url.searchParams.get("workingDirectory");
            if (!workingDir) {
              return Response.json(
                { error: "Missing required query parameter: workingDirectory" },
                { status: 400, headers: corsHeaders }
              );
            }
            const storeResult = getStoreAndEmitter(workingDir);
            if (!storeResult) {
              return Response.json(
                { error: `No store found for working directory: ${workingDir}` },
                { status: 404, headers: corsHeaders }
              );
            }
            const { store } = storeResult;
            if (!store.isDbHealthy()) {
              return Response.json(
                { error: `Database is not accessible. Path: ${store.getDbPath()}` },
                { status: 503, headers: corsHeaders }
              );
            }

            const suggestionId = path.slice("/suggestions/".length);
            const suggestion = store.getSuggestion(suggestionId);
            
            if (!suggestion) {
              return Response.json(
                { error: `Suggestion not found: ${suggestionId}` },
                { status: 404, headers: corsHeaders }
              );
            }

            const hunkStates: Record<string, unknown> = {};
            for (const [key, value] of suggestion.hunkStates) {
              hunkStates[key] = value;
            }

            return Response.json(
              {
                ...suggestion,
                hunkStates,
                remainingCount: store.getRemainingCount(suggestionId),
              },
              { headers: corsHeaders }
            );
          } catch (error) {
            const errorMsg = error instanceof Error ? error.message : String(error);
            console.error(`[HTTP Server] Error getting suggestion:`, errorMsg);
            return Response.json(
              { error: `Database error: ${errorMsg}` },
              { status: 503, headers: corsHeaders }
            );
          }
        }

        // Submit hunk feedback (HTTP)
        if (path === "/feedback" && method === "POST") {
          const body = await req.json() as HunkFeedback & { workingDirectory: string };
          
          if (!body.suggestionId || !body.hunkId || !body.action || !body.workingDirectory) {
            return Response.json(
              { error: "Missing required fields: suggestionId, hunkId, action, workingDirectory" },
              { status: 400, headers: corsHeaders }
            );
          }

          if (!["accept", "reject", "modify"].includes(body.action)) {
            return Response.json(
              { error: "Invalid action. Must be: accept, reject, or modify" },
              { status: 400, headers: corsHeaders }
            );
          }

          const result = await processFeedback(body);
          if (!result.success) {
            return Response.json(result, { status: result.error?.includes("not found") ? 404 : 500, headers: corsHeaders });
          }
          return Response.json(result, { headers: corsHeaders });
        }

        // Complete suggestion (HTTP)
        if (path === "/complete" && method === "POST") {
          const body = await req.json() as SuggestionComplete & { workingDirectory: string };

          if (!body.suggestionId || !body.action || !body.workingDirectory) {
            return Response.json(
              { error: "Missing required fields: suggestionId, action, workingDirectory" },
              { status: 400, headers: corsHeaders }
            );
          }

          if (!["finalize", "discard"].includes(body.action)) {
            return Response.json(
              { error: "Invalid action. Must be: finalize or discard" },
              { status: 400, headers: corsHeaders }
            );
          }

          const result = await processComplete(body);
          if (!result.success) {
            return Response.json(result, { status: 404, headers: corsHeaders });
          }
          return Response.json(result, { headers: corsHeaders });
        }

        // 404 for unknown routes
        return Response.json(
          { error: "Not found" },
          { status: 404, headers: corsHeaders }
        );

      } catch (error) {
        return Response.json(
          { error: error instanceof Error ? error.message : "Internal server error" },
          { status: 500, headers: corsHeaders }
        );
      }
    },

    websocket: {
      open(ws) {
        wsClients.add(ws);
        
        // Send connected message - client must subscribe to a working directory first
        ws.send(JSON.stringify({ 
          type: "connected", 
          message: "Connected. Send {type: 'subscribe', workingDirectory: '/path'} to filter suggestions.",
        }));
      },

      message(ws, message) {
        handleWSMessage(ws, message.toString());
      },

      close(ws) {
        wsClients.delete(ws);
      },
    },
  });

  return server;
}
