import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { SuggestionStore, generateSuggestionId } from "../src/suggestion-store.ts";
import type { Hunk, HunkFeedback } from "../src/types.ts";
import { existsSync, unlinkSync } from "fs";

describe("SuggestionStore", () => {
  let store: SuggestionStore;
  const testDbPath = ".opencode/test-codeforge.db";

  beforeEach(() => {
    // Clean up any existing test database
    if (existsSync(testDbPath)) {
      unlinkSync(testDbPath);
    }
    store = new SuggestionStore({ dbPath: testDbPath });
  });

  afterEach(() => {
    store.close();
    // Clean up test database
    if (existsSync(testDbPath)) {
      unlinkSync(testDbPath);
    }
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
        workingDirectory: "/test/project",
      });

      expect(suggestion.id).toBe(id);
      expect(suggestion.jjChangeId).toBe("abc123");
      expect(suggestion.description).toBe("Test suggestion");
      expect(suggestion.files).toEqual(["src/a.ts", "src/b.ts"]);
      expect(suggestion.hunks).toHaveLength(3);
      expect(suggestion.status).toBe("pending");
      expect(suggestion.createdAt).toBeGreaterThan(0);
      expect(suggestion.workingDirectory).toBe("/test/project");
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
        workingDirectory: "/test/project",
      });

      expect(suggestion.hunkStates.size).toBe(3);
      for (const state of suggestion.hunkStates.values()) {
        expect(state.reviewed).toBe(false);
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
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
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
        workingDirectory: "/test/project",
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
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
      });

      const hunk = store.getHunk(id, "non-existent");
      expect(hunk).toBeUndefined();
    });
  });

  describe("updateHunkState", () => {
    test("removes hunk on accept and logs feedback", () => {
      const id = "test-suggestion-6";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
        workingDirectory: "/test/project",
      });

      const hunkId = `${id}:src/a.ts:0`;
      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId,
        action: "accept",
      };

      const result = store.updateHunkState(id, hunkId, feedback, true);
      expect(result).toBe(true);

      // Hunk should be removed
      const hunk = store.getHunk(id, hunkId);
      expect(hunk).toBeUndefined();

      // Remaining count should be 2
      expect(store.getRemainingCount(id)).toBe(2);

      // Feedback should be logged
      const log = store.getFeedbackLog();
      expect(log).toHaveLength(1);
      expect(log[0]?.action).toBe("accept");
      expect(log[0]?.applied).toBe(true);
    });

    test("removes hunk on reject", () => {
      const id = "test-suggestion-7";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
        workingDirectory: "/test/project",
      });

      const hunkId = `${id}:src/a.ts:0`;
      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId,
        action: "reject",
        comment: "Not needed",
      };

      const result = store.updateHunkState(id, hunkId, feedback, false);
      expect(result).toBe(true);

      // Hunk should be removed
      expect(store.getHunk(id, hunkId)).toBeUndefined();

      // Feedback should include comment
      const log = store.getFeedbackLog();
      expect(log[0]?.comment).toBe("Not needed");
      expect(log[0]?.applied).toBe(false);
    });

    test("removes hunk on modify with modified diff", () => {
      const id = "test-suggestion-8";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
        workingDirectory: "/test/project",
      });

      const hunkId = `${id}:src/a.ts:0`;
      const modifiedDiff = "@@ -1,3 +1,5 @@\n+modified\n+extra\n context";
      const feedback: HunkFeedback = {
        suggestionId: id,
        hunkId,
        action: "modify",
        modifiedDiff,
      };

      const result = store.updateHunkState(id, hunkId, feedback, true);
      expect(result).toBe(true);

      // Feedback should include modified diff
      const log = store.getFeedbackLog();
      expect(log[0]?.modifiedDiff).toBe(modifiedDiff);
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
        workingDirectory: "/test/project",
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
        workingDirectory: "/test/project",
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
        workingDirectory: "/test/project",
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

  describe("getRemainingCount", () => {
    test("returns correct counts as hunks are processed", () => {
      const id = "test-suggestion-13";
      const hunks = createTestHunks(id);

      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["src/a.ts", "src/b.ts"],
        hunks,
        workingDirectory: "/test/project",
      });

      expect(store.getRemainingCount(id)).toBe(3);

      store.updateHunkState(
        id,
        `${id}:src/a.ts:0`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:0`, action: "accept" },
        true
      );

      expect(store.getRemainingCount(id)).toBe(2);

      store.updateHunkState(
        id,
        `${id}:src/a.ts:1`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:1`, action: "reject" },
        false
      );

      expect(store.getRemainingCount(id)).toBe(1);
    });
  });

  describe("listSuggestions", () => {
    test("returns all suggestions with pending hunks", () => {
      store.createSuggestion({
        id: "suggestion-1",
        jjChangeId: "abc123",
        description: "First",
        files: ["a.ts"],
        hunks: [{ id: "suggestion-1:a.ts:0", file: "a.ts", diff: "diff1" }],
        workingDirectory: "/test/project",
      });

      store.createSuggestion({
        id: "suggestion-2",
        jjChangeId: "def456",
        description: "Second",
        files: ["b.ts"],
        hunks: [{ id: "suggestion-2:b.ts:0", file: "b.ts", diff: "diff2" }],
        workingDirectory: "/test/project",
      });

      const result = store.listSuggestions();

      expect(result.suggestions).toHaveLength(2);
      const ids = result.suggestions.map(s => s.id);
      expect(ids).toContain("suggestion-1");
      expect(ids).toContain("suggestion-2");
    });

    test("filters by working directory", () => {
      store.createSuggestion({
        id: "suggestion-1",
        jjChangeId: "abc123",
        description: "First",
        files: ["a.ts"],
        hunks: [{ id: "suggestion-1:a.ts:0", file: "a.ts", diff: "diff1" }],
        workingDirectory: "/project-a",
      });

      store.createSuggestion({
        id: "suggestion-2",
        jjChangeId: "def456",
        description: "Second",
        files: ["b.ts"],
        hunks: [{ id: "suggestion-2:b.ts:0", file: "b.ts", diff: "diff2" }],
        workingDirectory: "/project-b",
      });

      const result = store.listSuggestions("/project-a");

      expect(result.suggestions).toHaveLength(1);
      expect(result.suggestions[0]?.id).toBe("suggestion-1");
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
        workingDirectory: "/test/project",
      });

      store.updateHunkState(
        id,
        `${id}:src/a.ts:0`,
        { suggestionId: id, hunkId: `${id}:src/a.ts:0`, action: "accept" },
        true
      );

      const result = store.listSuggestions();

      // After processing one hunk, count should be 2 (remaining hunks)
      expect(result.suggestions[0]?.hunkCount).toBe(2);
      expect(result.suggestions[0]?.status).toBe("partial");
    });

    test("excludes suggestions with no remaining hunks", () => {
      const id = "suggestion-complete";
      
      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Complete",
        files: ["a.ts"],
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
      });

      // Process the only hunk
      store.updateHunkState(
        id,
        `${id}:a.ts:0`,
        { suggestionId: id, hunkId: `${id}:a.ts:0`, action: "accept" },
        true
      );

      const result = store.listSuggestions();
      
      // Suggestion should not appear since it has no remaining hunks
      expect(result.suggestions.find(s => s.id === id)).toBeUndefined();
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
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
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
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
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
        hunks: [{ id: "suggestion-6:a.ts:0", file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
      });

      store.clear();

      expect(store.listSuggestions().suggestions).toHaveLength(0);
      expect(store.getFeedbackLog()).toHaveLength(0);
    });
  });

  describe("persistence", () => {
    test("suggestions persist across store instances", () => {
      const id = "persistent-suggestion";
      
      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Persistent test",
        files: ["a.ts"],
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
      });

      store.close();

      // Create new store instance with same database
      const store2 = new SuggestionStore({ dbPath: testDbPath });
      
      const suggestion = store2.getSuggestion(id);
      expect(suggestion).toBeDefined();
      expect(suggestion?.description).toBe("Persistent test");
      
      store2.close();
      
      // Reopen for cleanup in afterEach
      store = new SuggestionStore({ dbPath: testDbPath });
    });

    test("feedback log persists across store instances", () => {
      const id = "feedback-suggestion";
      
      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Feedback test",
        files: ["a.ts"],
        hunks: [{ id: `${id}:a.ts:0`, file: "a.ts", diff: "diff" }],
        workingDirectory: "/test/project",
      });

      store.updateHunkState(
        id,
        `${id}:a.ts:0`,
        { suggestionId: id, hunkId: `${id}:a.ts:0`, action: "accept", comment: "LGTM" },
        true
      );

      store.close();

      // Create new store instance with same database
      const store2 = new SuggestionStore({ dbPath: testDbPath });
      
      const log = store2.getFeedbackLog();
      expect(log).toHaveLength(1);
      expect(log[0]?.comment).toBe("LGTM");
      
      store2.close();
      
      // Reopen for cleanup in afterEach
      store = new SuggestionStore({ dbPath: testDbPath });
    });
  });

  describe("originalLines support", () => {
    test("stores and retrieves originalLines", () => {
      const id = "original-lines-test";
      const originalLines = ["line 1", "line 2", "line 3"];
      
      store.createSuggestion({
        id,
        jjChangeId: "abc123",
        description: "Test",
        files: ["a.ts"],
        hunks: [{
          id: `${id}:a.ts:0`,
          file: "a.ts",
          diff: "@@ -1,3 +1,4 @@\n+added\n context",
          originalStartLine: 1,
          originalLines,
        }],
        workingDirectory: "/test/project",
      });

      const hunk = store.getHunk(id, `${id}:a.ts:0`);
      expect(hunk?.originalLines).toEqual(originalLines);
      expect(hunk?.originalStartLine).toBe(1);
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
