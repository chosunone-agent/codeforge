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
 *   {"type": "feedback", "suggestionId": "...", "hunkId": "...", "action": "accept|reject|modify", "modifiedDiff"?: "...", "comment"?: "..."}
 *   {"type": "complete", "suggestionId": "...", "action": "finalize|discard"}
 *   {"type": "list"}
 *   {"type": "get", "suggestionId": "..."}
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
import type { SuggestionStore } from "./suggestion-store.ts";
import type { SuggestionEventEmitter } from "./event-emitter.ts";
import type { HunkFeedback, SuggestionComplete, FeedbackResult } from "./types.ts";
import { applyHunkToFile, applyModifiedHunk, reverseHunk } from "./patch-applier.ts";

type OpencodeClient = ReturnType<typeof createOpencodeClient>;

export interface HttpServerConfig {
  port: number;
  host?: string;
}

export interface HttpServerDeps {
  store: SuggestionStore;
  emitter: SuggestionEventEmitter;
  workingDirectory: string;
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
        if (client.data.workingDirectory === workingDirectory) {
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
  const { store, emitter, workingDirectory, client } = deps;

  // Log file for debugging
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
   */
  async function processFeedback(body: HunkFeedback): Promise<FeedbackResult & { error?: string }> {
    const suggestion = store.getSuggestion(body.suggestionId);
    if (!suggestion) {
      return { success: false, applied: false, remainingHunks: 0, error: `Suggestion not found: ${body.suggestionId}` };
    }

    const hunk = store.getHunk(body.suggestionId, body.hunkId);
    if (!hunk) {
      return { success: false, applied: false, remainingHunks: 0, error: `Hunk not found: ${body.hunkId}` };
    }

    let applied = false;
    let reverted = false;

    const filePath = `${workingDirectory}/${hunk.file}`;

    if (body.action === "accept") {
      applied = true;
    } else if (body.action === "modify") {
      const revertResult = await applyHunkToFile(filePath, reverseHunk(hunk.diff));
      if (!revertResult.success) {
        await emitter.emitError("apply_failed", revertResult.error ?? "Failed to revert hunk for modification", body.suggestionId, body.hunkId);
        return { success: false, applied: false, remainingHunks: 0, error: revertResult.error };
      }

      const applyResult = await applyModifiedHunk(filePath, body.modifiedDiff!);
      if (!applyResult.success) {
        await emitter.emitError("apply_failed", applyResult.error ?? "Failed to apply modified hunk", body.suggestionId, body.hunkId);
        return { success: false, applied: false, remainingHunks: 0, error: applyResult.error };
      }

      applied = true;
    } else if (body.action === "reject") {
      const revertResult = await applyHunkToFile(filePath, reverseHunk(hunk.diff));
      if (!revertResult.success) {
        await emitter.emitError("apply_failed", revertResult.error ?? "Failed to revert rejected hunk", body.suggestionId, body.hunkId);
        return { success: false, applied: false, remainingHunks: 0, error: revertResult.error };
      }

      reverted = true;
    }

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
    await notifyAI(`[Suggestion Feedback] User ${actionVerb} hunk in ${hunk.file}. ${remaining} hunks remaining.${commentPart}`);

    return { success: true, applied, reverted, remainingHunks: remaining };
  }

  /**
   * Process complete request (shared between HTTP and WebSocket)
   */
  async function processComplete(body: SuggestionComplete): Promise<{ success: boolean; action?: string; error?: string }> {
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
          if (!parsed.suggestionId || !parsed.hunkId || !parsed.action) {
            respond({ success: false, error: "Missing required fields: suggestionId, hunkId, action" });
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
          });
          respond(result);
          break;
        }

        case "complete": {
          if (!parsed.suggestionId || !parsed.action) {
            respond({ success: false, error: "Missing required fields: suggestionId, action" });
            return;
          }
          if (!["finalize", "discard"].includes(parsed.action as string)) {
            respond({ success: false, error: "Invalid action. Must be: finalize or discard" });
            return;
          }
          const result = await processComplete({
            suggestionId: parsed.suggestionId as string,
            action: parsed.action as "finalize" | "discard",
          });
          respond(result);
          break;
        }

        case "list": {
          // Filter by client's working directory if set
          const result = store.listSuggestions(ws.data.workingDirectory);
          respond({ success: true, ...result });
          break;
        }

        case "subscribe": {
          // Client wants to subscribe to a specific working directory
          const wd = parsed.workingDirectory as string | undefined;
          ws.data.workingDirectory = wd;
          // Send filtered list
          const result = store.listSuggestions(wd);
          respond({ success: true, subscribed: wd, ...result });
          break;
        }

        case "get": {
          if (!parsed.suggestionId) {
            respond({ success: false, error: "Missing required field: suggestionId" });
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
          return Response.json(
            { healthy: true, service: "codeforge", wsClients: wsClients.size },
            { headers: corsHeaders }
          );
        }

        // List suggestions
        if (path === "/suggestions" && method === "GET") {
          const result = store.listSuggestions();
          return Response.json(result, { headers: corsHeaders });
        }

        // Get specific suggestion
        if (path.startsWith("/suggestions/") && method === "GET") {
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
        }

        // Submit hunk feedback (HTTP)
        if (path === "/feedback" && method === "POST") {
          const body = await req.json() as HunkFeedback;
          
          if (!body.suggestionId || !body.hunkId || !body.action) {
            return Response.json(
              { error: "Missing required fields: suggestionId, hunkId, action" },
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
          const body = await req.json() as SuggestionComplete;

          if (!body.suggestionId || !body.action) {
            return Response.json(
              { error: "Missing required fields: suggestionId, action" },
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
        // Send connected message - client should subscribe with workingDirectory to get filtered list
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
