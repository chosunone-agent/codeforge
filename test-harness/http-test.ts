#!/usr/bin/env bun
/**
 * HTTP Integration Test for Suggestion Manager
 * 
 * Tests the HTTP server endpoints directly, simulating how neovim
 * would communicate with the plugin.
 * 
 * This test:
 * 1. Starts the HTTP server with mock dependencies
 * 2. Creates a suggestion programmatically
 * 3. Sends feedback via HTTP endpoints
 * 4. Verifies the responses and state changes
 * 
 * Usage:
 *   bun run http-test.ts
 */

import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "bun";

// Import plugin components
import { SuggestionStore, generateSuggestionId } from "../plugin/src/suggestion-store.ts";
import { createHttpServer } from "../plugin/src/http-server.ts";
import { parseDiff, fileDiffsToHunks, getFilesFromDiff } from "../plugin/src/diff-parser.ts";
import type { Suggestion, HunkFeedback, SuggestionComplete } from "../plugin/src/types.ts";

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

// Mock event emitter that collects events
class MockEventEmitter {
  events: Array<{ type: string; data: unknown }> = [];

  async emitReady(suggestion: Suggestion) {
    this.events.push({ type: "suggestion.ready", data: suggestion });
  }

  async emitStatus(status: string, message: string, suggestionId?: string) {
    this.events.push({ type: "suggestion.status", data: { status, message, suggestionId } });
  }

  async emitHunkApplied(suggestionId: string, hunkId: string, action: string) {
    this.events.push({ type: "suggestion.hunk_applied", data: { suggestionId, hunkId, action } });
  }

  async emitError(code: string, message: string, suggestionId?: string, hunkId?: string) {
    this.events.push({ type: "suggestion.error", data: { code, message, suggestionId, hunkId } });
  }

  async emitList(suggestions: unknown[]) {
    this.events.push({ type: "suggestion.list", data: suggestions });
  }

  clear() {
    this.events = [];
  }
}

async function runTests() {
  let tempDir: string | null = null;
  let server: Server | null = null;
  let passed = 0;
  let failed = 0;

  const PORT = 14097; // Use a different port to avoid conflicts
  const BASE_URL = `http://127.0.0.1:${PORT}`;

  try {
    // Setup
    section("Setup");
    tempDir = await mkdtemp(join(tmpdir(), "http-test-"));
    log(`Created temp directory: ${tempDir}`);

    // Create test files
    const testFile1 = join(tempDir, "example.ts");
    await Bun.write(testFile1, `// Example file
function add(a: number, b: number): number {
  return a + b;
}

export { add };
`);
    pass("Created test file");

    // Initialize components
    const store = new SuggestionStore();
    const emitter = new MockEventEmitter();
    
    // Mock client that does nothing (for tests)
    const mockClient = {
      session: {
        list: async () => ({ data: [] }),
        prompt: async () => ({}),
      },
    } as any;

    // Start HTTP server
    server = createHttpServer(
      { port: PORT, host: "127.0.0.1" },
      { store, emitter, workingDirectory: tempDir, client: mockClient }
    );
    pass(`HTTP server started on port ${PORT}`);

    // Test 1: Health check
    section("Test 1: Health Check");
    {
      const res = await fetch(`${BASE_URL}/health`);
      const data = await res.json() as { healthy: boolean; service: string };
      
      if (res.ok && data.healthy && data.service === "suggestion-manager") {
        pass("Health check passed");
        passed++;
      } else {
        fail(`Health check failed: ${JSON.stringify(data)}`);
        failed++;
      }
    }

    // Test 2: List suggestions (empty)
    section("Test 2: List Suggestions (Empty)");
    {
      const res = await fetch(`${BASE_URL}/suggestions`);
      const data = await res.json() as { suggestions: unknown[] };
      
      if (res.ok && data.suggestions.length === 0) {
        pass("Empty suggestions list");
        passed++;
      } else {
        fail(`Expected empty list, got: ${JSON.stringify(data)}`);
        failed++;
      }
    }

    // Create a suggestion programmatically (simulating what publish_suggestion tool does)
    section("Setup: Create Suggestion");
    
    const testDiff = `diff --git a/example.ts b/example.ts
--- a/example.ts
+++ b/example.ts
@@ -1,5 +1,6 @@
 // Example file
+// Added validation
 function add(a: number, b: number): number {
   return a + b;
 }
@@ -4,4 +5,5 @@ function add(a: number, b: number): number {
   return a + b;
 }
 
+// New comment
 export { add };
`;

    const fileDiffs = parseDiff(testDiff);
    const suggestionId = generateSuggestionId();
    const hunks = fileDiffsToHunks(fileDiffs, suggestionId);
    const files = getFilesFromDiff(testDiff);

    const suggestion = store.createSuggestion({
      id: suggestionId,
      jjChangeId: "test-change-abc",
      description: "Add comments to example.ts",
      files,
      hunks,
    });

    log(`Created suggestion: ${suggestionId}`);
    log(`Hunks: ${hunks.map(h => h.id).join(", ")}`);
    pass("Suggestion created");

    // Test 3: List suggestions (with one)
    section("Test 3: List Suggestions (With One)");
    {
      const res = await fetch(`${BASE_URL}/suggestions`);
      const data = await res.json() as { suggestions: Array<{ id: string }> };
      
      if (res.ok && data.suggestions.length === 1 && data.suggestions[0]?.id === suggestionId) {
        pass("Suggestions list contains our suggestion");
        passed++;
      } else {
        fail(`Expected 1 suggestion, got: ${JSON.stringify(data)}`);
        failed++;
      }
    }

    // Test 4: Get specific suggestion
    section("Test 4: Get Suggestion");
    {
      const res = await fetch(`${BASE_URL}/suggestions/${suggestionId}`);
      const data = await res.json() as { id: string; hunks: unknown[]; description: string };
      
      if (res.ok && data.id === suggestionId && data.hunks.length === 2) {
        pass("Got suggestion details");
        passed++;
      } else {
        fail(`Unexpected response: ${JSON.stringify(data)}`);
        failed++;
      }
    }

    // Test 5: Get non-existent suggestion
    section("Test 5: Get Non-Existent Suggestion");
    {
      const res = await fetch(`${BASE_URL}/suggestions/fake-id`);
      
      if (res.status === 404) {
        pass("404 for non-existent suggestion");
        passed++;
      } else {
        fail(`Expected 404, got ${res.status}`);
        failed++;
      }
    }

    // Test 6: Submit feedback - accept first hunk
    section("Test 6: Accept Hunk via HTTP");
    {
      const hunk = hunks[0]!;
      emitter.clear();

      const feedback: HunkFeedback = {
        suggestionId,
        hunkId: hunk.id,
        action: "accept",
        comment: "Looks good!",
      };

      const res = await fetch(`${BASE_URL}/feedback`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(feedback),
      });

      const data = await res.json() as { success: boolean; applied: boolean; remainingHunks: number };

      if (res.ok && data.success && data.applied && data.remainingHunks === 1) {
        pass("Accepted hunk via HTTP");
        passed++;
      } else {
        fail(`Unexpected response: ${JSON.stringify(data)}`);
        failed++;
      }

      // Check events were emitted
      const hunkAppliedEvents = emitter.events.filter(e => e.type === "suggestion.hunk_applied");
      if (hunkAppliedEvents.length === 1) {
        pass("hunk_applied event emitted");
        passed++;
      } else {
        fail(`Expected 1 hunk_applied event, got ${hunkAppliedEvents.length}`);
        failed++;
      }

      // Verify file was modified
      const content = await Bun.file(testFile1).text();
      if (content.includes("// Added validation")) {
        pass("File was modified correctly");
        passed++;
      } else {
        fail("File was not modified");
        log(`${c.dim}Content: ${content}${c.reset}`);
        failed++;
      }
    }

    // Test 7: Submit feedback - reject second hunk
    section("Test 7: Reject Hunk via HTTP");
    {
      const hunk = hunks[1]!;
      emitter.clear();

      const feedback: HunkFeedback = {
        suggestionId,
        hunkId: hunk.id,
        action: "reject",
        comment: "Don't need this",
      };

      const res = await fetch(`${BASE_URL}/feedback`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(feedback),
      });

      const data = await res.json() as { success: boolean; applied: boolean; remainingHunks: number };

      if (res.ok && data.success && !data.applied && data.remainingHunks === 0) {
        pass("Rejected hunk via HTTP");
        passed++;
      } else {
        fail(`Unexpected response: ${JSON.stringify(data)}`);
        failed++;
      }

      // Verify file was NOT modified with the rejected content
      const content = await Bun.file(testFile1).text();
      if (!content.includes("// New comment")) {
        pass("Rejected content not in file");
        passed++;
      } else {
        fail("Rejected content was applied");
        failed++;
      }
    }

    // Test 8: Verify suggestion is complete
    section("Test 8: Suggestion Complete");
    {
      const res = await fetch(`${BASE_URL}/suggestions/${suggestionId}`);
      const data = await res.json() as { status: string; reviewedCount: number; remainingCount: number };

      if (data.status === "complete" && data.reviewedCount === 2 && data.remainingCount === 0) {
        pass("Suggestion marked as complete");
        passed++;
      } else {
        fail(`Unexpected state: ${JSON.stringify(data)}`);
        failed++;
      }
    }

    // Test 9: Invalid feedback
    section("Test 9: Invalid Feedback");
    {
      // Missing required fields
      const res = await fetch(`${BASE_URL}/feedback`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ suggestionId }),
      });

      if (res.status === 400) {
        pass("400 for missing fields");
        passed++;
      } else {
        fail(`Expected 400, got ${res.status}`);
        failed++;
      }
    }

    // Test 10: Complete suggestion (discard)
    section("Test 10: Complete Suggestion");
    {
      // Create another suggestion to test complete
      const newId = generateSuggestionId();
      store.createSuggestion({
        id: newId,
        jjChangeId: "test-change-xyz",
        description: "Test suggestion for discard",
        files: ["test.ts"],
        hunks: [{
          id: `${newId}-0`,
          suggestionId: newId,
          file: "test.ts",
          startLine: 1,
          endLine: 2,
          diff: "@@ -1 +1 @@\n-old\n+new",
        }],
      });

      const complete: SuggestionComplete = {
        suggestionId: newId,
        action: "discard",
      };

      const res = await fetch(`${BASE_URL}/complete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(complete),
      });

      const data = await res.json() as { success: boolean; action: string };

      if (res.ok && data.success && data.action === "discarded") {
        pass("Discarded suggestion via HTTP");
        passed++;
      } else {
        fail(`Unexpected response: ${JSON.stringify(data)}`);
        failed++;
      }

      // Verify it's gone
      const listRes = await fetch(`${BASE_URL}/suggestions`);
      const listData = await listRes.json() as { suggestions: Array<{ id: string }> };
      const found = listData.suggestions.find(s => s.id === newId);
      
      if (!found) {
        pass("Discarded suggestion removed from list");
        passed++;
      } else {
        fail("Discarded suggestion still in list");
        failed++;
      }
    }

    // Test 11: CORS headers
    section("Test 11: CORS Headers");
    {
      const res = await fetch(`${BASE_URL}/health`, { method: "OPTIONS" });
      const corsHeader = res.headers.get("Access-Control-Allow-Origin");
      
      if (corsHeader === "*") {
        pass("CORS headers present");
        passed++;
      } else {
        fail(`Missing CORS header: ${corsHeader}`);
        failed++;
      }
    }

    // Summary
    section("Summary");
    console.log(`${c.green}Passed: ${passed}${c.reset}`);
    console.log(`${c.red}Failed: ${failed}${c.reset}`);

    if (failed === 0) {
      console.log(`\n${c.green}All HTTP tests passed!${c.reset}\n`);
    } else {
      console.log(`\n${c.red}Some tests failed.${c.reset}\n`);
      process.exit(1);
    }

  } finally {
    // Cleanup
    if (server) {
      server.stop();
      log(`${c.dim}Stopped HTTP server${c.reset}`);
    }
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
