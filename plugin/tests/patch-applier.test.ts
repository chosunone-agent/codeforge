import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { applyHunk, applyHunkToFile, reverseHunk } from "../src/patch-applier.ts";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("applyHunk", () => {
  test("applies a simple replacement", () => {
    const original = `line 1
line 2
line 3
line 4
line 5`;

    const hunk = `@@ -2,3 +2,3 @@
 line 2
-line 3
+line 3 modified
 line 4`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1
line 2
line 3 modified
line 4
line 5`);
  });

  test("applies an addition", () => {
    const original = `line 1
line 2
line 3`;

    const hunk = `@@ -1,3 +1,5 @@
 line 1
+added 1
+added 2
 line 2
 line 3`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1
added 1
added 2
line 2
line 3`);
  });

  test("applies a deletion", () => {
    const original = `line 1
line 2
line 3
line 4`;

    const hunk = `@@ -1,4 +1,2 @@
 line 1
-line 2
-line 3
 line 4`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1
line 4`);
  });

  test("applies hunk at end of file", () => {
    const original = `line 1
line 2
line 3`;

    const hunk = `@@ -2,2 +2,3 @@
 line 2
-line 3
+line 3 modified
+new line`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1
line 2
line 3 modified
new line`);
  });

  test("applies hunk at start of file", () => {
    const original = `line 1
line 2
line 3`;

    const hunk = `@@ -1,2 +1,3 @@
+new first line
 line 1
 line 2`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`new first line
line 1
line 2
line 3`);
  });

  test("fails on context mismatch", () => {
    const original = `line 1
line 2
line 3`;

    const hunk = `@@ -1,2 +1,2 @@
 wrong context
-line 2
+line 2 modified`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(false);
    expect(result.error).toContain("Context mismatch");
  });

  test("fails on invalid hunk header", () => {
    const original = "line 1";
    const hunk = "not a valid hunk";

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(false);
    expect(result.error).toContain("Invalid hunk");
  });

  test("handles empty lines in diff", () => {
    const original = `line 1

line 3`;

    const hunk = `@@ -1,3 +1,3 @@
 line 1

-line 3
+line 3 modified`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1

line 3 modified`);
  });

  test("handles 'no newline at end of file' marker", () => {
    const original = `line 1
line 2`;

    const hunk = `@@ -1,2 +1,2 @@
 line 1
-line 2
\\ No newline at end of file
+line 2 modified
\\ No newline at end of file`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1
line 2 modified`);
  });

  test("handles single line hunk (no count in header)", () => {
    const original = `line 1
line 2
line 3`;

    // @@ -2 +2 @@ means single line at position 2
    const hunk = `@@ -2 +2 @@
-line 2
+line 2 modified`;

    const result = applyHunk(original, hunk);

    expect(result.success).toBe(true);
    expect(result.newContent).toBe(`line 1
line 2 modified
line 3`);
  });
});

describe("applyHunkToFile", () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "patch-test-"));
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
  });

  test("applies hunk to file on disk", async () => {
    const filePath = join(tempDir, "test.txt");
    await Bun.write(filePath, `line 1
line 2
line 3`);

    const hunk = `@@ -2 +2 @@
-line 2
+line 2 modified`;

    const result = await applyHunkToFile(filePath, hunk);

    expect(result.success).toBe(true);

    const content = await Bun.file(filePath).text();
    expect(content).toBe(`line 1
line 2 modified
line 3`);
  });

  test("creates new file for new file hunk", async () => {
    const filePath = join(tempDir, "new-file.txt");

    const hunk = `@@ -0,0 +1,3 @@
+line 1
+line 2
+line 3`;

    const result = await applyHunkToFile(filePath, hunk);

    expect(result.success).toBe(true);

    const content = await Bun.file(filePath).text();
    expect(content).toBe(`line 1
line 2
line 3`);
  });

  test("fails for non-existent file (non-new-file hunk)", async () => {
    const filePath = join(tempDir, "does-not-exist.txt");

    const hunk = `@@ -1,2 +1,2 @@
 line 1
-line 2
+line 2 modified`;

    const result = await applyHunkToFile(filePath, hunk);

    expect(result.success).toBe(false);
    expect(result.error).toContain("File not found");
  });
});

describe("reverseHunk", () => {
  test("reverses a simple hunk", () => {
    const hunk = `@@ -10,3 +10,4 @@
 context
-removed
+added1
+added2
 context`;

    const reversed = reverseHunk(hunk);

    expect(reversed).toBe(`@@ -10,4 +10,3 @@
 context
+removed
-added1
-added2
 context`);
  });

  test("reverses hunk with single line counts", () => {
    const hunk = `@@ -5 +5 @@
-old
+new`;

    const reversed = reverseHunk(hunk);

    expect(reversed).toBe(`@@ -5 +5 @@
+old
-new`);
  });

  test("preserves context lines", () => {
    const hunk = `@@ -1,5 +1,5 @@
 line 1
 line 2
-old
+new
 line 4
 line 5`;

    const reversed = reverseHunk(hunk);

    // Context lines should remain unchanged
    expect(reversed).toContain(" line 1");
    expect(reversed).toContain(" line 2");
    expect(reversed).toContain(" line 4");
    expect(reversed).toContain(" line 5");
    // Additions become removals and vice versa
    expect(reversed).toContain("+old");
    expect(reversed).toContain("-new");
  });

  test("preserves no-newline markers", () => {
    const hunk = `@@ -1,2 +1,2 @@
 line 1
-old
\\ No newline at end of file
+new
\\ No newline at end of file`;

    const reversed = reverseHunk(hunk);

    expect(reversed).toContain("\\ No newline at end of file");
  });
});
