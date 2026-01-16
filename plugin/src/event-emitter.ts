/**
 * Event emission for suggestion events
 * 
 * Events are emitted via:
 * 1. OpenCode's app.log() API (for SSE filtering by neovim)
 * 2. WebSocket broadcast (for real-time bidirectional communication)
 * 
 * Events are logged with:
 * - service: "codeforge"
 * - level: "info" 
 * - message: JSON stringified event
 * - extra: { event: true, eventType: "<type>" }
 */

import type { createOpencodeClient } from "@opencode-ai/sdk";
import type {
  SuggestionEvent,
  SuggestionReadyEvent,
  SuggestionErrorEvent,
  SuggestionStatusEvent,
  SuggestionHunkAppliedEvent,
  SuggestionListEvent,
  Suggestion,
} from "./types.ts";
import { broadcast } from "./http-server.ts";

export type OpencodeClient = ReturnType<typeof createOpencodeClient>;

const SERVICE_NAME = "codeforge";

// Store for AI notifications (feedback received)
interface AINotification {
  timestamp: number;
  suggestionId: string;
  hunkId: string;
  file: string;
  action: "accepted" | "rejected" | "modified";
  comment?: string;
}

// Recent notifications for AI to query
const aiNotifications: AINotification[] = [];
const MAX_NOTIFICATIONS = 100;

/**
 * Event emitter that sends events via OpenCode's log API
 */
export class SuggestionEventEmitter {
  private client: OpencodeClient;

  constructor(client: OpencodeClient) {
    this.client = client;
  }

  /**
   * Add a notification for the AI about feedback received
   */
  notifyAI(notification: Omit<AINotification, "timestamp">): void {
    aiNotifications.push({
      ...notification,
      timestamp: Date.now(),
    });
    // Keep only recent notifications
    while (aiNotifications.length > MAX_NOTIFICATIONS) {
      aiNotifications.shift();
    }
  }

  /**
   * Get pending AI notifications (and optionally clear them)
   */
  static getAINotifications(clear: boolean = false): AINotification[] {
    const notifications = [...aiNotifications];
    if (clear) {
      aiNotifications.length = 0;
    }
    return notifications;
  }

  /**
   * Clear all AI notifications
   */
  static clearAINotifications(): void {
    aiNotifications.length = 0;
  }

  /**
   * Emit a suggestion event
   * @param workingDirectory If specified, only broadcast to clients subscribed to this directory
   */
  async emit(event: SuggestionEvent, workingDirectory?: string): Promise<void> {
    // Broadcast to WebSocket clients (filtered by working directory if specified)
    broadcast(event, workingDirectory);
    
    // Also log via OpenCode's API (for SSE fallback)
    try {
      await this.client.app.log({
        body: {
          service: SERVICE_NAME,
          level: "info",
          message: JSON.stringify(event),
          extra: {
            event: true,
            eventType: event.type,
          },
        },
      });
    } catch {
      // Silently fail - WebSocket broadcast is primary
    }
  }

  /**
   * Emit suggestion.ready event
   */
  async emitReady(suggestion: Suggestion): Promise<void> {
    const event: SuggestionReadyEvent = {
      type: "suggestion.ready",
      suggestion: {
        id: suggestion.id,
        jjChangeId: suggestion.jjChangeId,
        description: suggestion.description,
        files: suggestion.files,
        hunks: suggestion.hunks,
        workingDirectory: suggestion.workingDirectory,
      },
    };
    // Only broadcast to clients subscribed to this suggestion's working directory
    await this.emit(event, suggestion.workingDirectory);
  }

  /**
   * Emit suggestion.error event
   */
  async emitError(
    code: SuggestionErrorEvent["code"],
    message: string,
    suggestionId?: string,
    hunkId?: string
  ): Promise<void> {
    const event: SuggestionErrorEvent = {
      type: "suggestion.error",
      code,
      message,
      suggestionId,
      hunkId,
    };
    await this.emit(event);
  }

  /**
   * Emit suggestion.status event
   */
  async emitStatus(
    status: SuggestionStatusEvent["status"],
    message: string,
    suggestionId?: string
  ): Promise<void> {
    const event: SuggestionStatusEvent = {
      type: "suggestion.status",
      status,
      message,
      suggestionId,
    };
    await this.emit(event);
  }

  /**
   * Emit suggestion.hunk_applied event
   */
  async emitHunkApplied(
    suggestionId: string,
    hunkId: string,
    action: SuggestionHunkAppliedEvent["action"]
  ): Promise<void> {
    const event: SuggestionHunkAppliedEvent = {
      type: "suggestion.hunk_applied",
      suggestionId,
      hunkId,
      action,
    };
    await this.emit(event);
  }

  /**
   * Emit suggestion.list event
   */
  async emitList(
    suggestions: SuggestionListEvent["suggestions"]
  ): Promise<void> {
    const event: SuggestionListEvent = {
      type: "suggestion.list",
      suggestions,
    };
    await this.emit(event);
  }
}

/**
 * Parse a log message to extract a suggestion event (if it is one)
 * Used by the neovim side to filter events from the SSE stream
 */
export function parseLogEvent(logMessage: string, extra?: Record<string, unknown>): SuggestionEvent | null {
  // Check if this is a suggestion event
  if (!extra?.event || extra?.eventType === undefined) {
    return null;
  }

  try {
    const event = JSON.parse(logMessage) as SuggestionEvent;
    
    // Validate event type
    const validTypes = [
      "suggestion.ready",
      "suggestion.error", 
      "suggestion.status",
      "suggestion.hunk_applied",
      "suggestion.list",
    ];
    
    if (!validTypes.includes(event.type)) {
      return null;
    }

    return event;
  } catch {
    return null;
  }
}

/**
 * Check if a log entry is from the codeforge service
 */
export function isCodeForgeLog(service: string): boolean {
  return service === SERVICE_NAME;
}
