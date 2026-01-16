import { describe, expect, test, beforeEach } from "bun:test";
import { SuggestionStore, generateSuggestionId } from "../src/suggestion-store.ts";
import type { Hunk, HunkFeedback } from "../src/types.ts";

describe("SuggestionStore", () => {
  let store: SuggestionStore;

  beforeEach(() => {
    store = new SuggestionStore();
  });

  const createTestHunks = (suggestionId: string): Hunk[] => [
    {
      id: `${suggestionId}:src/a.ts:0`,
      file: "src/a.ts",
      diff: "@@ -1,3 +1,4 @@\n+added\n context",
    },
    {
      id: `${suggestionId}:src/a.ts:1`,
      file: "src/a.ts",
      diff: "@@ -10,2 +11,3 @@\n context\n+added",
    },
    {
      id: `${suggestionId}:src/b.ts:0`,
      file: "src/b.ts",
      diff: "@@ -5 +5 @@\n-old\n+new",
    },
  ];

  describe("createSuggestion", () => {
    test("creates a suggestion with correct initial state", () => {
      const id = "test-suggestion-1";
      const hunks = createTestHunks(id);

      const suggestion = store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test suggestion",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      expect(suggestion.id).toBe(id);
      expect(suggestion.jjChangeId).toBe("abc123");
      expect(suggestion.description).toBe("Test suggestion");
      expect(suggestion.files).toEqual(["src/a.ts", "src/b.ts"]);
      expect(suggestion.hunks).toHaveLength(3);
      expect(suggestion.status).toBe("pending");
      expect(suggestion.createdAt).toBeGreaterThan(0);
    });

    test("initializes all hunk states as unreviewed", () => {
      const id = "test-suggestion-2";
      const hunks = createTestHunks(id);

      const suggestion = store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      expect(suggestion.hunkStates.size).toBe(3);
      for (const state of suggestion.hunkStates.values()) {
        expect(state.reviewed).toBe(false);
        expect(state.action).toBeUndefined();
      }
    });
  });

  describe("getSuggestion", () => {
    test("returns suggestion by ID", () => {
      const id = "test-suggestion-3";
      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: [],
        hunks: [],
      });

      const suggestion = store.getSuggestion(id);
      expect(suggestion).toBeDefined();
      expect(suggestion?.id).toBe(id);
    });

    test("returns undefined for non-existent ID", () => {
      const suggestion = store.getSuggestion("non-existent");
      expect(suggestion).toBeUndefined();
    });
  });

  describe("getHunk", () => {
    test("returns hunk by ID", () => {
      const id = "test-suggestion-4";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      const hunk = store.getHunk(id, `${id}:src/a.ts:0`);
      expect(hunk).toBeDefined();
      expect(hunk?.file).toBe("src/a.ts");
    });

    test("returns undefined for non-existent hunk", () => {
      const id = "test-suggestion-5";
      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: [],
        hunks: [],
      });

      const hunk = store.getHunk(id, "non-existent");
      expect(hunk).toBeUndefined();
    });
  });

  describe("updateHunkState", () => {
    test("updates hunk state on accept", () => {
      const id = "test-suggestion-6";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId: `${id}:src/a.ts:0`,
        action: "accept",
      };

      const result = store.updateHunkState(id, feedback.hunkId, feedback, true);
      expect(result).toBe(true);

      const state = store.getHunkState(id, feedback.hunkId);
      expect(state?.reviewed).toBe(true);
      expect(state?.action).toBe("accepted");
      expect(state?.appliedAt).toBeGreaterThan(0);
    });

    test("updates hunk state on reject", () => {
      const id = "test-suggestion-7";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId: `${id}:src/a.ts:0`,
        action: "reject",
        comment: "Not needed",
      };

      const result = store.updateHunkState(id, feedback.hunkId, feedback, false);
      expect(result).toBe(true);

      const state = store.getHunkState(id, feedback.hunkId);
      expect(state?.reviewed).toBe(true);
      expect(state?.action).toBe("rejected");
      expect(state?.comment).toBe("Not needed");
      expect(state?.appliedAt).toBeUndefined();
    });

    test("updates hunk state on modify", () => {
      const id = "test-suggestion-8";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      const modifiedDiff = "@@ -1,3 +1,5 @@\n+modified\n+extra\n context";
      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId: `${id}:src/a.ts:0`,
        action: "modify",
        modifiedDiff,
      };

      const result = store.updateHunkState(id, feedback.hunkId, feedback, true);
      expect(result).toBe(true);

      const state = store.getHunkState(id, feedback.hunkId);
      expect(state?.reviewed).toBe(true);
      expect(state?.action).toBe("modified");
      expect(state?.modifiedDiff).toBe(modifiedDiff);
    });

    test("returns false for non-existent suggestion", () => {
      const feedback: HunkFeedback = {
        suggestionId: "non-existent",
        hunkId: "non-existent:file:0",
        action: "accept",
      };

      const result = store.updateHunkState("non-existent", feedback.hunkId, feedback, true);
      expect(result).toBe(false);
    });

    test("logs feedback entry", () => {
      const id = "test-suggestion-9";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId: `${id}:src/a.ts:0`,
        action: "accept",
        comment: "Looks good",
      };

      store.updateHunkState(id, feedback.hunkId, feedback, true);

      const log = store.getFeedbackLog();
      expect(log).toHaveLength(1);
      expect(log[0]?.suggestionId).toBe(id);
      expect(log[0]?.hunkId).toBe(feedback.hunkId);
      expect(log[0]?.action).toBe("accept");
      expect(log[0]?.comment).toBe("Looks good");
      expect(log[0]?.applied).toBe(true);
    });
  });

  describe("suggestion status updates", () => {
    test("status is pending when no hunks reviewed", () => {
      const id = "test-suggestion-10";
      const hunks = createTestHunks(id);

      const suggestion = store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      expect(suggestion.status).toBe("pending");
    });

    test("status is partial when some hunks reviewed", () => {
      const id = "test-suggestion-11";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      store.updateHunkState(
        id,
        `${id}:src/a.ts:0`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:0`, action: "accept" },
        true
      );

      const suggestion = store.getSuggestion(id);
      expect(suggestion?.status).toBe("partial");
    });

    test("status is complete when all hunks reviewed", () => {
      const id = "test-suggestion-12";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      // Review all hunks
      for (const hunk of hunks) {
        store.updateHunkState(
          id,
          hunk.id,
          { suggestionId: id, hunkId: hunk.id, action: "accept" },
          true
        );
      }

      const suggestion = store.getSuggestion(id);
      expect(suggestion?.status).toBe("complete");
    });
  });

  describe("getReviewedCount and getRemainingCount", () => {
    test("returns correct counts", () => {
      const id = "test-suggestion-13";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      expect(store.getReviewedCount(id)).toBe(0);
      expect(store.getRemainingCount(id)).toBe(3);

      store.updateHunkState(
        id,
        `${id}:src/a.ts:0`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:0`, action: "accept" },
        true
      );

      expect(store.getReviewedCount(id)).toBe(1);
      expect(store.getRemainingCount(id)).toBe(2);

      store.updateHunkState(
        id,
        `${id}:src/a.ts:1`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:1`, action: "reject" },
        false
      );

      expect(store.getReviewedCount(id)).toBe(2);
      expect(store.getRemainingCount(id)).toBe(1);
    });
  });

  describe("listSuggestions", () => {
    test("returns all suggestions", () => {
      store.createSuggestion({
        id: "suggestion-1",
        jjChangeId: "abc123",
        description: "First",
        files: ["a.ts"],
        hunks: [{ id: "suggestion-1:a.ts:0", file: "a.ts", diff: "diff1" }],
      });

      store.createSuggestion({
        id: "suggestion-2",
        jjChangeId: "def456",
        description: "Second",
        files: ["b.ts"],
        hunks: [{ id: "suggestion-2:b.ts:0", file: "b.ts", diff: "diff2" }],
      });

      const result = store.listSuggestions();

      expect(result.suggestions).toHaveLength(2);
      // Both suggestions should be present (order may vary due to same timestamp)
      const ids = result.suggestions.map(s => s.id);
      expect(ids).toContain("suggestion-1");
      expect(ids).toContain("suggestion-2");
    });

    test("includes correct counts", () => {
      const id = "suggestion-3";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
      });

      store.updateHunkState(
        id,
        `${id}:src/a.ts:0`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:0`, action: "accept" },
        true
      );

      const result = store.listSuggestions();

      expect(result.suggestions[0]?.hunkCount).toBe(3);
      expect(result.suggestions[0]?.reviewedCount).toBe(1);
      expect(result.suggestions[0]?.status).toBe("partial");
    });
  });

  describe("discardSuggestion", () => {
    test("marks suggestion as discarded", () => {
      const id = "suggestion-4";

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: [],
        hunks: [],
      });

      const result = store.discardSuggestion(id);
      expect(result).toBe(true);

      const suggestion = store.getSuggestion(id);
      expect(suggestion?.status).toBe("discarded");
    });

    test("returns false for non-existent suggestion", () => {
      const result = store.discardSuggestion("non-existent");
      expect(result).toBe(false);
    });
  });

  describe("removeSuggestion", () => {
    test("removes suggestion from store", () => {
      const id = "suggestion-5";

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: [],
        hunks: [],
      });

      expect(store.getSuggestion(id)).toBeDefined();

      const result = store.removeSuggestion(id);
      expect(result).toBe(true);
      expect(store.getSuggestion(id)).toBeUndefined();
    });
  });

  describe("clear", () => {
    test("clears all suggestions and feedback log", () => {
      store.createSuggestion({
        id: "suggestion-6",
        jjChangeId: "abc123",
        description: "Test",
        files: [],
        hunks: [],
      });

      store.clear();

      expect(store.listSuggestions().suggestions).toHaveLength(0);
      expect(store.getFeedbackLog()).toHaveLength(0);
    });
  });
});

describe("generateSuggestionId", () => {
  test("generates unique UUIDs", () => {
    const id1 = generateSuggestionId();
    const id2 = generateSuggestionId();

    expect(id1).not.toBe(id2);
    // UUID format check
    expect(id1).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  });
});
