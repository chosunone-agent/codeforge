/**
 * HTTP Server for Suggestion Manager
 * 
 * Exposes endpoints for the editor (neovim/test harness) to send
 * feedback directly using our protocol, without going through the AI.
 */

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

/**
 * Create and start the HTTP server
 */
export function createHttpServer(
  config: HttpServerConfig,
  deps: HttpServerDeps
): ReturnType<typeof Bun.serve> {
  const { store, emitter, workingDirectory, client } = deps;

  /**
   * Notify the AI about feedback by injecting a message into the current session
   */
  async function notifyAI(message: string): Promise<void> {
    try {
      // Get the current session
      const sessions = await client.session.list();
      if (!sessions.data || sessions.data.length === 0) {
        console.log("[suggestion-manager] No active session to notify");
        return;
      }
      
      // Find the most recent active session
      const activeSession = sessions.data[0];
      if (!activeSession?.id) {
        return;
      }

      // Inject the feedback notification as a user message (no AI reply)
      await client.session.prompt({
        path: { id: activeSession.id },
        body: {
          noReply: true,
          parts: [{ type: "text", text: message }],
        },
      });
      
      console.log("[suggestion-manager] Notified AI:", message);
    } catch (error) {
      console.error("[suggestion-manager] Failed to notify AI:", error);
    }
  }

  const server = Bun.serve({
    port: config.port,
    hostname: config.host ?? "127.0.0.1",

    async fetch(req) {
      const url = new URL(req.url);
      const path = url.pathname;
      const method = req.method;

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
            { healthy: true, service: "suggestion-manager" },
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

          // Convert Map to object
          const hunkStates: Record<string, unknown> = {};
          for (const [key, value] of suggestion.hunkStates) {
            hunkStates[key] = value;
          }

          return Response.json(
            {
              ...suggestion,
              hunkStates,
              reviewedCount: store.getReviewedCount(suggestionId),
              remainingCount: store.getRemainingCount(suggestionId),
            },
            { headers: corsHeaders }
          );
        }

        // Submit hunk feedback
        if (path === "/feedback" && method === "POST") {
          const body = await req.json() as HunkFeedback;
          
          // Validate required fields
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

          const suggestion = store.getSuggestion(body.suggestionId);
          if (!suggestion) {
            return Response.json(
              { error: `Suggestion not found: ${body.suggestionId}` },
              { status: 404, headers: corsHeaders }
            );
          }

          const hunk = store.getHunk(body.suggestionId, body.hunkId);
          if (!hunk) {
            return Response.json(
              { error: `Hunk not found: ${body.hunkId}` },
              { status: 404, headers: corsHeaders }
            );
          }

          let applied = false;
          let reverted = false;

          const filePath = `${workingDirectory}/${hunk.file}`;

          if (body.action === "accept") {
            // Accept: hunk is already in working copy, nothing to do
            applied = true;
          } else if (body.action === "modify") {
            // Modify: revert original, apply modified version
            const revertResult = await applyHunkToFile(filePath, reverseHunk(hunk.diff));
            if (!revertResult.success) {
              await emitter.emitError(
                "apply_failed",
                revertResult.error ?? "Failed to revert hunk for modification",
                body.suggestionId,
                body.hunkId
              );
              return Response.json(
                { success: false, error: revertResult.error, applied: false },
                { status: 500, headers: corsHeaders }
              );
            }

            const applyResult = await applyModifiedHunk(filePath, body.modifiedDiff!);
            if (!applyResult.success) {
              await emitter.emitError(
                "apply_failed",
                applyResult.error ?? "Failed to apply modified hunk",
                body.suggestionId,
                body.hunkId
              );
              return Response.json(
                { success: false, error: applyResult.error, applied: false },
                { status: 500, headers: corsHeaders }
              );
            }

            applied = true;
          } else if (body.action === "reject") {
            // Reject: revert the hunk (undo the AI's change)
            const revertResult = await applyHunkToFile(filePath, reverseHunk(hunk.diff));
            if (!revertResult.success) {
              await emitter.emitError(
                "apply_failed",
                revertResult.error ?? "Failed to revert rejected hunk",
                body.suggestionId,
                body.hunkId
              );
              return Response.json(
                { success: false, error: revertResult.error, applied: false },
                { status: 500, headers: corsHeaders }
              );
            }

            reverted = true;
          }

          // Update the store
          store.updateHunkState(body.suggestionId, body.hunkId, body, applied || reverted);

          // Emit events
          const action = body.action === "accept" ? "accepted"
            : body.action === "reject" ? "rejected"
            : "modified";
          await emitter.emitHunkApplied(body.suggestionId, body.hunkId, action);

          const remaining = store.getRemainingCount(body.suggestionId);
          const reviewed = store.getReviewedCount(body.suggestionId);
          const total = suggestion.hunks.length;
          await emitter.emitStatus(
            remaining === 0 ? "applied" : "partial",
            `${reviewed}/${total} hunks reviewed`,
            body.suggestionId
          );

          // Notify the AI about the feedback
          const actionVerb = body.action === "accept" ? "accepted" 
            : body.action === "reject" ? "rejected" 
            : "modified";
          const commentPart = body.comment ? ` Comment: "${body.comment}"` : "";
          await notifyAI(
            `[Suggestion Feedback] User ${actionVerb} hunk in ${hunk.file}. ` +
            `Progress: ${reviewed}/${total} hunks reviewed.${commentPart}`
          );

          const result: FeedbackResult = {
            success: true,
            applied,
            reverted,
            remainingHunks: remaining,
          };

          return Response.json(result, { headers: corsHeaders });
        }

        // Complete suggestion
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

          const suggestion = store.getSuggestion(body.suggestionId);
          if (!suggestion) {
            return Response.json(
              { error: `Suggestion not found: ${body.suggestionId}` },
              { status: 404, headers: corsHeaders }
            );
          }

          if (body.action === "finalize") {
            await emitter.emitStatus("applied", "Suggestion finalized", body.suggestionId);
            store.removeSuggestion(body.suggestionId);
            return Response.json(
              { success: true, action: "finalized" },
              { headers: corsHeaders }
            );
          } else {
            store.discardSuggestion(body.suggestionId);
            store.removeSuggestion(body.suggestionId);
            await emitter.emitStatus("applied", "Suggestion discarded", body.suggestionId);
            return Response.json(
              { success: true, action: "discarded" },
              { headers: corsHeaders }
            );
          }
        }

        // 404 for unknown routes
        return Response.json(
          { error: "Not found" },
          { status: 404, headers: corsHeaders }
        );

      } catch (error) {
        console.error("HTTP server error:", error);
        return Response.json(
          { error: error instanceof Error ? error.message : "Internal server error" },
          { status: 500, headers: corsHeaders }
        );
      }
    },
  });

  console.log(`[suggestion-manager] HTTP server listening on http://${config.host ?? "127.0.0.1"}:${config.port}`);

  return server;
}
