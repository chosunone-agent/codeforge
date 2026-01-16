#!/usr/bin/env bun
/**
 * Direct Test Harness for Suggestion Manager
 * 
 * Tests the plugin components directly without going through OpenCode.
 * This simulates the full flow:
 * 1. Create a test repo with jj
 * 2. Make some changes
 * 3. Publish a suggestion
 * 4. Review hunks (accept/reject/modify)
 * 5. Verify the results
 * 
 * Usage:
 *   bun run direct-test.ts
 */

import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Import plugin components
import { SuggestionStore, generateSuggestionId } from "../plugin/src/suggestion-store.ts";
import { parseDiff, fileDiffsToHunks, getFilesFromDiff } from "../plugin/src/diff-parser.ts";
import { applyHunkToFile } from "../plugin/src/patch-applier.ts";
import type { HunkFeedback, Suggestion } from "../plugin/src/types.ts";

// Colors
const c = {
  reset: "\x1b[0m",
  green: "\x1b[32m",
  red: "\x1b[31m",
  yellow: "\x1b[33m",
  cyan: "\x1b[36m",
  dim: "\x1b[2m",
};

function log(msg: string) {
  console.log(msg);
}

function pass(msg: string) {
  console.log(`${c.green}✓${c.reset} ${msg}`);
}

function fail(msg: string) {
  console.log(`${c.red}✗${c.reset} ${msg}`);
}

function section(msg: string) {
  console.log(`\n${c.cyan}═══ ${msg} ═══${c.reset}\n`);
}

// Mock event emitter that just logs events
class MockEventEmitter {
  events: Array<{ type: string; data: unknown }> = [];

  async emit(event: { type: string; [key: string]: unknown }) {
    this.events.push({ type: event.type, data: event });
    log(`${c.dim}  [EVENT] ${event.type}${c.reset}`);
  }

  async emitReady(suggestion: Suggestion) {
    await this.emit({ type: "suggestion.ready", suggestion });
  }

  async emitStatus(status: string, message: string, suggestionId?: string) {
    await this.emit({ type: "suggestion.status", status, message, suggestionId });
  }

  async emitHunkApplied(suggestionId: string, hunkId: string, action: string) {
    await this.emit({ type: "suggestion.hunk_applied", suggestionId, hunkId, action });
  }

  async emitError(code: string, message: string, suggestionId?: string, hunkId?: string) {
    await this.emit({ type: "suggestion.error", code, message, suggestionId, hunkId });
  }
}

async function runTests() {
  let tempDir: string | null = null;
  let passed = 0;
  let failed = 0;

  try {
    // Setup
    section("Setup");
    tempDir = await mkdtemp(join(tmpdir(), "suggestion-test-"));
    log(`Created temp directory: ${tempDir}`);

    // Create test files
    const testFile1 = join(tempDir, "example.ts");
    const testFile2 = join(tempDir, "utils.ts");

    await Bun.write(testFile1, `// Example file
function add(a: number, b: number): number {
  return a + b;
}

function subtract(a: number, b: number): number {
  return a - b;
}

export { add, subtract };
`);

    await Bun.write(testFile2, `// Utils
export function log(msg: string) {
  console.log(msg);
}
`);

    pass("Created test files");

    // Test 1: Diff Parser
    section("Test 1: Diff Parser");

    const testDiff = `diff --git a/example.ts b/example.ts
--- a/example.ts
+++ b/example.ts
@@ -1,5 +1,6 @@
 // Example file
 function add(a: number, b: number): number {
+  // Add validation
   return a + b;
 }
 
@@ -7,4 +8,5 @@ function subtract(a: number, b: number): number {
   return a - b;
 }
 
+// New export
 export { add, subtract };
diff --git a/utils.ts b/utils.ts
--- a/utils.ts
+++ b/utils.ts
@@ -1,4 +1,5 @@
 // Utils
 export function log(msg: string) {
-  console.log(msg);
+  const timestamp = new Date().toISOString();
+  console.log(\`[\${timestamp}] \${msg}\`);
 }
`;

    const fileDiffs = parseDiff(testDiff);
    
    if (fileDiffs.length === 2) {
      pass(`Parsed ${fileDiffs.length} file diffs`);
      passed++;
    } else {
      fail(`Expected 2 file diffs, got ${fileDiffs.length}`);
      failed++;
    }

    const files = getFilesFromDiff(testDiff);
    if (files.length === 2 && files.includes("example.ts") && files.includes("utils.ts")) {
      pass(`Extracted files: ${files.join(", ")}`);
      passed++;
    } else {
      fail(`Expected [example.ts, utils.ts], got ${files}`);
      failed++;
    }

    const suggestionId = generateSuggestionId();
    const hunks = fileDiffsToHunks(fileDiffs, suggestionId);
    
    if (hunks.length === 3) {
      pass(`Created ${hunks.length} hunks`);
      passed++;
    } else {
      fail(`Expected 3 hunks, got ${hunks.length}`);
      failed++;
    }

    log(`${c.dim}  Hunk IDs: ${hunks.map(h => h.id).join(", ")}${c.reset}`);

    // Test 2: Suggestion Store
    section("Test 2: Suggestion Store");

    const store = new SuggestionStore();
    const emitter = new MockEventEmitter();

    const suggestion = store.createSuggestion({
      id: suggestionId,
      jjChangeId: "test-change-123",
      description: "Add validation and improve logging",
      files,
      hunks,
    });

    if (suggestion.status === "pending") {
      pass("Created suggestion with pending status");
      passed++;
    } else {
      fail(`Expected pending status, got ${suggestion.status}`);
      failed++;
    }

    if (store.getRemainingCount(suggestionId) === 3) {
      pass("All 3 hunks are unreviewed");
      passed++;
    } else {
      fail(`Expected 3 remaining, got ${store.getRemainingCount(suggestionId)}`);
      failed++;
    }

    // Test 3: Accept a hunk
    section("Test 3: Accept Hunk");

    const hunk1 = hunks[0]!;
    log(`Accepting hunk: ${hunk1.id}`);
    log(`${c.dim}${hunk1.diff}${c.reset}`);

    // Apply the hunk to the file
    const applyResult = await applyHunkToFile(testFile1, hunk1.diff);
    
    if (applyResult.success) {
      pass("Applied hunk to file");
      passed++;

      // Update store
      const feedback: HunkFeedback = {
        suggestionId,
        hunkId: hunk1.id,
        action: "accept",
        comment: "Looks good!",
      };
      store.updateHunkState(suggestionId, hunk1.id, feedback, true);
      await emitter.emitHunkApplied(suggestionId, hunk1.id, "accepted");

      // Verify file content
      const content = await Bun.file(testFile1).text();
      if (content.includes("// Add validation")) {
        pass("File contains the added comment");
        passed++;
      } else {
        fail("File does not contain the added comment");
        failed++;
      }
    } else {
      fail(`Failed to apply hunk: ${applyResult.error}`);
      failed++;
    }

    if (store.getReviewedCount(suggestionId) === 1) {
      pass("1 hunk reviewed");
      passed++;
    } else {
      fail(`Expected 1 reviewed, got ${store.getReviewedCount(suggestionId)}`);
      failed++;
    }

    if (store.getSuggestion(suggestionId)?.status === "partial") {
      pass("Suggestion status is partial");
      passed++;
    } else {
      fail(`Expected partial status, got ${store.getSuggestion(suggestionId)?.status}`);
      failed++;
    }

    // Test 4: Reject a hunk
    section("Test 4: Reject Hunk");

    const hunk2 = hunks[1]!;
    log(`Rejecting hunk: ${hunk2.id}`);

    const rejectFeedback: HunkFeedback = {
      suggestionId,
      hunkId: hunk2.id,
      action: "reject",
      comment: "Don't need this export comment",
    };
    store.updateHunkState(suggestionId, hunk2.id, rejectFeedback, false);
    await emitter.emitHunkApplied(suggestionId, hunk2.id, "rejected");

    const hunk2State = store.getHunkState(suggestionId, hunk2.id);
    if (hunk2State?.action === "rejected") {
      pass("Hunk marked as rejected");
      passed++;
    } else {
      fail(`Expected rejected, got ${hunk2State?.action}`);
      failed++;
    }

    // Test 5: Modify a hunk
    section("Test 5: Modify Hunk");

    const hunk3 = hunks[2]!;
    log(`Modifying hunk: ${hunk3.id}`);
    log(`Original diff:\n${c.dim}${hunk3.diff}${c.reset}`);

    // Create a modified version of the diff
    const modifiedDiff = `@@ -1,4 +1,6 @@
 // Utils
+// Enhanced logging with timestamps
 export function log(msg: string) {
-  console.log(msg);
+  const ts = Date.now();
+  console.log(\`[\${ts}] \${msg}\`);
 }
`;

    log(`Modified diff:\n${c.dim}${modifiedDiff}${c.reset}`);

    const modifyResult = await applyHunkToFile(testFile2, modifiedDiff);
    
    if (modifyResult.success) {
      pass("Applied modified hunk");
      passed++;

      const modifyFeedback: HunkFeedback = {
        suggestionId,
        hunkId: hunk3.id,
        action: "modify",
        modifiedDiff,
        comment: "Simplified the timestamp format",
      };
      store.updateHunkState(suggestionId, hunk3.id, modifyFeedback, true);
      await emitter.emitHunkApplied(suggestionId, hunk3.id, "modified");

      // Verify file content
      const content = await Bun.file(testFile2).text();
      if (content.includes("Date.now()") && content.includes("Enhanced logging")) {
        pass("File contains modified content");
        passed++;
      } else {
        fail("File does not contain expected modified content");
        log(`${c.dim}Actual content:\n${content}${c.reset}`);
        failed++;
      }
    } else {
      fail(`Failed to apply modified hunk: ${modifyResult.error}`);
      failed++;
    }

    // Test 6: Final state
    section("Test 6: Final State");

    if (store.getReviewedCount(suggestionId) === 3) {
      pass("All 3 hunks reviewed");
      passed++;
    } else {
      fail(`Expected 3 reviewed, got ${store.getReviewedCount(suggestionId)}`);
      failed++;
    }

    if (store.getSuggestion(suggestionId)?.status === "complete") {
      pass("Suggestion status is complete");
      passed++;
    } else {
      fail(`Expected complete status, got ${store.getSuggestion(suggestionId)?.status}`);
      failed++;
    }

    // Check feedback log
    const feedbackLog = store.getFeedbackLog();
    if (feedbackLog.length === 3) {
      pass("Feedback log has 3 entries");
      passed++;
      
      const actions = feedbackLog.map(f => f.action);
      if (actions.includes("accept") && actions.includes("reject") && actions.includes("modify")) {
        pass("All action types recorded");
        passed++;
      } else {
        fail(`Expected all action types, got ${actions}`);
        failed++;
      }
    } else {
      fail(`Expected 3 feedback entries, got ${feedbackLog.length}`);
      failed++;
    }

    // Test 7: List suggestions
    section("Test 7: List Suggestions");

    const list = store.listSuggestions();
    if (list.suggestions.length === 1) {
      pass("List contains 1 suggestion");
      passed++;
      
      const s = list.suggestions[0]!;
      if (s.reviewedCount === 3 && s.hunkCount === 3 && s.status === "complete") {
        pass("Suggestion summary is correct");
        passed++;
      } else {
        fail(`Unexpected summary: ${JSON.stringify(s)}`);
        failed++;
      }
    } else {
      fail(`Expected 1 suggestion, got ${list.suggestions.length}`);
      failed++;
    }

    // Test 8: Events emitted
    section("Test 8: Events");

    const eventTypes = emitter.events.map(e => e.type);
    if (eventTypes.filter(t => t === "suggestion.hunk_applied").length === 3) {
      pass("3 hunk_applied events emitted");
      passed++;
    } else {
      fail(`Expected 3 hunk_applied events`);
      failed++;
    }

    // Summary
    section("Summary");
    console.log(`${c.green}Passed: ${passed}${c.reset}`);
    console.log(`${c.red}Failed: ${failed}${c.reset}`);

    if (failed === 0) {
      console.log(`\n${c.green}All tests passed!${c.reset}\n`);
    } else {
      console.log(`\n${c.red}Some tests failed.${c.reset}\n`);
      process.exit(1);
    }

  } finally {
    // Cleanup
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
      log(`${c.dim}Cleaned up temp directory${c.reset}`);
    }
  }
}

runTests().catch((error) => {
  console.error(`${c.red}Test error:${c.reset}`, error);
  process.exit(1);
});
