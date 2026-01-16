import { describe, expect, test, mock } from "bun:test";
import {
  SuggestionEventEmitter,
  parseLogEvent,
  isSuggestionManagerLog,
} from "../src/event-emitter.ts";
import type { Suggestion, SuggestionEvent } from "../src/types.ts";

// Type alias for test assertions
type EventType = SuggestionEvent["type"];

// Mock OpenCode client
function createMockClient() {
  const logCalls: Array<{ body: unknown }> = [];

  return {
    client: {
      app: {
        log: mock(async (params: { body: unknown }) => {
          logCalls.push(params);
          return { data: true };
        }),
      },
    },
    logCalls,
  };
}

describe("SuggestionEventEmitter", () => {
  describe("emit", () => {
    test("emits event via client.app.log", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      const event: SuggestionEvent = {
        type: "suggestion.status",
        status: "working",
        message: "Processing...",
      };

      await emitter.emit(event);

      expect(logCalls).toHaveLength(1);
      expect(logCalls[0]?.body).toEqual({
        service: "suggestion-manager",
        level: "info",
        message: JSON.stringify(event),
        extra: {
          event: true,
          eventType: "suggestion.status",
        },
      });
    });
  });

  describe("emitReady", () => {
    test("emits suggestion.ready event", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      const suggestion: Suggestion = {
        id: "test-123",
        jjChangeId: "abc123",
        description: "Test suggestion",
        files: ["src/a.ts"],
        hunks: [{ id: "test-123:src/a.ts:0", file: "src/a.ts", diff: "diff" }],
        status: "pending",
        createdAt: Date.now(),
        hunkStates: new Map(),
      };

      await emitter.emitReady(suggestion);

      expect(logCalls).toHaveLength(1);
      const body = logCalls[0]?.body as any;
      expect(body.extra.eventType).toBe("suggestion.ready");

      const event = JSON.parse(body.message);
      expect(event.type).toBe("suggestion.ready");
      expect(event.suggestion.id).toBe("test-123");
      expect(event.suggestion.hunks).toHaveLength(1);
    });
  });

  describe("emitError", () => {
    test("emits suggestion.error event", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      await emitter.emitError("jj_error", "Failed to get diff", "sugg-1", "hunk-1");

      expect(logCalls).toHaveLength(1);
      const body = logCalls[0]?.body as any;
      expect(body.extra.eventType).toBe("suggestion.error");

      const event = JSON.parse(body.message);
      expect(event.type).toBe("suggestion.error");
      expect(event.code).toBe("jj_error");
      expect(event.message).toBe("Failed to get diff");
      expect(event.suggestionId).toBe("sugg-1");
      expect(event.hunkId).toBe("hunk-1");
    });

    test("emits error without optional fields", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      await emitter.emitError("unknown", "Something went wrong");

      const body = logCalls[0]?.body as any;
      const event = JSON.parse(body.message);
      expect(event.suggestionId).toBeUndefined();
      expect(event.hunkId).toBeUndefined();
    });
  });

  describe("emitStatus", () => {
    test("emits suggestion.status event", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      await emitter.emitStatus("testing", "Running tests...", "sugg-1");

      expect(logCalls).toHaveLength(1);
      const body = logCalls[0]?.body as any;
      expect(body.extra.eventType).toBe("suggestion.status");

      const event = JSON.parse(body.message);
      expect(event.type).toBe("suggestion.status");
      expect(event.status).toBe("testing");
      expect(event.message).toBe("Running tests...");
      expect(event.suggestionId).toBe("sugg-1");
    });
  });

  describe("emitHunkApplied", () => {
    test("emits suggestion.hunk_applied event", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      await emitter.emitHunkApplied("sugg-1", "hunk-1", "accepted");

      expect(logCalls).toHaveLength(1);
      const body = logCalls[0]?.body as any;
      expect(body.extra.eventType).toBe("suggestion.hunk_applied");

      const event = JSON.parse(body.message);
      expect(event.type).toBe("suggestion.hunk_applied");
      expect(event.suggestionId).toBe("sugg-1");
      expect(event.hunkId).toBe("hunk-1");
      expect(event.action).toBe("accepted");
    });
  });

  describe("emitList", () => {
    test("emits suggestion.list event", async () => {
      const { client, logCalls } = createMockClient();
      const emitter = new SuggestionEventEmitter(client as any);

      const suggestions = [
        {
          id: "sugg-1",
          jjChangeId: "abc",
          description: "First",
          files: ["a.ts"],
          hunkCount: 2,
          reviewedCount: 1,
          status: "partial" as const,
        },
      ];

      await emitter.emitList(suggestions);

      expect(logCalls).toHaveLength(1);
      const body = logCalls[0]?.body as any;
      expect(body.extra.eventType).toBe("suggestion.list");

      const event = JSON.parse(body.message);
      expect(event.type).toBe("suggestion.list");
      expect(event.suggestions).toHaveLength(1);
      expect(event.suggestions[0].id).toBe("sugg-1");
    });
  });
});

describe("parseLogEvent", () => {
  test("parses valid suggestion event", () => {
    const event: SuggestionEvent = {
      type: "suggestion.status",
      status: "working",
      message: "Processing...",
    };

    const result = parseLogEvent(JSON.stringify(event), {
      event: true,
      eventType: "suggestion.status",
    });

    expect(result).toEqual(event);
  });

  test("returns null for non-event log", () => {
    const result = parseLogEvent("Regular log message", {});
    expect(result).toBeNull();
  });

  test("returns null when extra.event is false", () => {
    const event = { type: "suggestion.status", status: "working", message: "test" };
    const result = parseLogEvent(JSON.stringify(event), { event: false });
    expect(result).toBeNull();
  });

  test("returns null for invalid JSON", () => {
    const result = parseLogEvent("not json", { event: true, eventType: "suggestion.status" });
    expect(result).toBeNull();
  });

  test("returns null for unknown event type", () => {
    const event = { type: "unknown.event", data: "test" };
    const result = parseLogEvent(JSON.stringify(event), {
      event: true,
      eventType: "unknown.event",
    });
    expect(result).toBeNull();
  });

  test("parses all valid event types", () => {
    const eventTypes: Array<{ type: string; [key: string]: unknown }> = [
      { type: "suggestion.ready", suggestion: { id: "1", jjChangeId: "a", description: "d", files: [], hunks: [] } },
      { type: "suggestion.error", code: "unknown", message: "error" },
      { type: "suggestion.status", status: "working", message: "msg" },
      { type: "suggestion.hunk_applied", suggestionId: "1", hunkId: "2", action: "accepted" },
      { type: "suggestion.list", suggestions: [] },
    ];

    for (const event of eventTypes) {
      const result = parseLogEvent(JSON.stringify(event), {
        event: true,
        eventType: event.type,
      });
      expect(result).not.toBeNull();
      expect(result?.type).toBe(event.type as EventType);
    }
  });
});

describe("isSuggestionManagerLog", () => {
  test("returns true for suggestion-manager service", () => {
    expect(isSuggestionManagerLog("suggestion-manager")).toBe(true);
  });

  test("returns false for other services", () => {
    expect(isSuggestionManagerLog("other-service")).toBe(false);
    expect(isSuggestionManagerLog("")).toBe(false);
  });
});
