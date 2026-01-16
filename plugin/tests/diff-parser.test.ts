import { describe, expect, test } from "bun:test";
import {
  parseDiff,
  fileDiffsToHunks,
  getFilesFromDiff,
  extractHunkContent,
  type FileDiff,
} from "../src/diff-parser.ts";

describe("parseDiff", () => {
  test("parses a simple single-file diff", () => {
    const diff = `diff --git a/src/example.ts b/src/example.ts
--- a/src/example.ts
+++ b/src/example.ts
@@ -10,7 +10,9 @@ function example() {
   const x = 1;
   const y = 2;
-  return x + y;
+  // Add validation
+  if (x < 0 || y < 0) throw new Error("negative");
+  return x + y;
   // trailing context
 }`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.oldPath).toBe("src/example.ts");
    expect(result[0]!.newPath).toBe("src/example.ts");
    expect(result[0]!.hunks).toHaveLength(1);

    const hunk = result[0]!.hunks[0]!;
    expect(hunk.oldStart).toBe(10);
    expect(hunk.oldCount).toBe(7);
    expect(hunk.newStart).toBe(10);
    expect(hunk.newCount).toBe(9);
    expect(hunk.context).toBe("function example() {");
    expect(hunk.content).toContain("@@ -10,7 +10,9 @@");
    expect(hunk.content).toContain("-  return x + y;");
    expect(hunk.content).toContain("+  // Add validation");
  });

  test("parses multiple hunks in a single file", () => {
    const diff = `diff --git a/src/file.ts b/src/file.ts
--- a/src/file.ts
+++ b/src/file.ts
@@ -1,3 +1,4 @@
+// Header comment
 const a = 1;
 const b = 2;
 const c = 3;
@@ -20,4 +21,5 @@ function foo() {
   return bar;
 }
+// Footer comment
 export default foo;`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.hunks).toHaveLength(2);

    expect(result[0]!.hunks[0]!.oldStart).toBe(1);
    expect(result[0]!.hunks[0]!.newStart).toBe(1);

    expect(result[0]!.hunks[1]!.oldStart).toBe(20);
    expect(result[0]!.hunks[1]!.newStart).toBe(21);
  });

  test("parses multiple files", () => {
    const diff = `diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,3 +1,3 @@
-const old = 1;
+const new = 1;
 export default old;
diff --git a/src/b.ts b/src/b.ts
--- a/src/b.ts
+++ b/src/b.ts
@@ -5,3 +5,4 @@
 function test() {
   return true;
 }
+// Added`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(2);
    expect(result[0]!.newPath).toBe("src/a.ts");
    expect(result[1]!.newPath).toBe("src/b.ts");
  });

  test("handles new file creation", () => {
    const diff = `diff --git a/src/new-file.ts b/src/new-file.ts
--- /dev/null
+++ b/src/new-file.ts
@@ -0,0 +1,5 @@
+// New file
+export function hello() {
+  return "world";
+}
+`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.oldPath).toBe("/dev/null");
    expect(result[0]!.newPath).toBe("src/new-file.ts");
    expect(result[0]!.hunks).toHaveLength(1);
    expect(result[0]!.hunks[0]!.oldStart).toBe(0);
    expect(result[0]!.hunks[0]!.oldCount).toBe(0);
    expect(result[0]!.hunks[0]!.newStart).toBe(1);
    expect(result[0]!.hunks[0]!.newCount).toBe(5);
  });

  test("handles file deletion", () => {
    const diff = `diff --git a/src/deleted.ts b/src/deleted.ts
--- a/src/deleted.ts
+++ /dev/null
@@ -1,3 +0,0 @@
-// This file is deleted
-export const x = 1;
-`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.oldPath).toBe("src/deleted.ts");
    expect(result[0]!.newPath).toBe("/dev/null");
  });

  test("handles jj diff format", () => {
    const diff = `diff -r abc123 def456 src/file.ts
--- a/src/file.ts
+++ b/src/file.ts
@@ -1,3 +1,3 @@
-old
+new
 context`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.newPath).toBe("src/file.ts");
  });

  test("handles hunk without count (single line)", () => {
    const diff = `diff --git a/file.ts b/file.ts
--- a/file.ts
+++ b/file.ts
@@ -5 +5 @@
-old line
+new line`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.hunks).toHaveLength(1);
    expect(result[0]!.hunks[0]!.oldCount).toBe(1);
    expect(result[0]!.hunks[0]!.newCount).toBe(1);
  });

  test("handles empty diff", () => {
    const result = parseDiff("");
    expect(result).toHaveLength(0);
  });

  test("handles diff with no newline at end of file marker", () => {
    const diff = `diff --git a/file.ts b/file.ts
--- a/file.ts
+++ b/file.ts
@@ -1,2 +1,2 @@
 line1
-line2
\\ No newline at end of file
+line2 modified
\\ No newline at end of file`;

    const result = parseDiff(diff);

    expect(result).toHaveLength(1);
    expect(result[0]!.hunks[0]!.content).toContain("\\ No newline at end of file");
  });
});

describe("fileDiffsToHunks", () => {
  test("converts file diffs to hunks with proper IDs", () => {
    const fileDiffs: FileDiff[] = [
      {
        oldPath: "src/a.ts",
        newPath: "src/a.ts",
        hunks: [
          { oldStart: 1, oldCount: 3, newStart: 1, newCount: 4, content: "@@ -1,3 +1,4 @@\n+added\n context" },
          { oldStart: 10, oldCount: 2, newStart: 11, newCount: 3, content: "@@ -10,2 +11,3 @@\n context\n+added" },
        ],
      },
      {
        oldPath: "src/b.ts",
        newPath: "src/b.ts",
        hunks: [
          { oldStart: 5, oldCount: 1, newStart: 5, newCount: 1, content: "@@ -5 +5 @@\n-old\n+new" },
        ],
      },
    ];

    const hunks = fileDiffsToHunks(fileDiffs, "suggestion-123");

    expect(hunks).toHaveLength(3);
    expect(hunks[0]!.id).toBe("suggestion-123:src/a.ts:0");
    expect(hunks[0]!.file).toBe("src/a.ts");
    expect(hunks[1]!.id).toBe("suggestion-123:src/a.ts:1");
    expect(hunks[2]!.id).toBe("suggestion-123:src/b.ts:0");
    expect(hunks[2]!.file).toBe("src/b.ts");
  });

  test("handles empty file diffs", () => {
    const hunks = fileDiffsToHunks([], "suggestion-123");
    expect(hunks).toHaveLength(0);
  });
});

describe("getFilesFromDiff", () => {
  test("extracts unique file paths", () => {
    const diff = `diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1 +1 @@
-old
+new
diff --git a/src/b.ts b/src/b.ts
--- a/src/b.ts
+++ b/src/b.ts
@@ -1 +1 @@
-old
+new`;

    const files = getFilesFromDiff(diff);

    expect(files).toHaveLength(2);
    expect(files).toContain("src/a.ts");
    expect(files).toContain("src/b.ts");
  });

  test("handles new files (uses newPath)", () => {
    const diff = `diff --git a/src/new.ts b/src/new.ts
--- /dev/null
+++ b/src/new.ts
@@ -0,0 +1 @@
+content`;

    const files = getFilesFromDiff(diff);

    expect(files).toHaveLength(1);
    expect(files[0]).toBe("src/new.ts");
  });

  test("handles deleted files (uses oldPath)", () => {
    const diff = `diff --git a/src/deleted.ts b/src/deleted.ts
--- a/src/deleted.ts
+++ /dev/null
@@ -1 +0,0 @@
-content`;

    const files = getFilesFromDiff(diff);

    expect(files).toHaveLength(1);
    expect(files[0]).toBe("src/deleted.ts");
  });
});

describe("extractHunkContent", () => {
  test("extracts original and modified lines", () => {
    const hunkDiff = `@@ -10,5 +10,6 @@ function example() {
   const x = 1;
   const y = 2;
-  return x + y;
+  // Add validation
+  if (x < 0) throw new Error();
+  return x + y;
   // trailing
 }`;

    const result = extractHunkContent(hunkDiff);

    expect(result.original).toEqual([
      "  const x = 1;",
      "  const y = 2;",
      "  return x + y;",
      "  // trailing",
      "}",
    ]);

    expect(result.modified).toEqual([
      "  const x = 1;",
      "  const y = 2;",
      "  // Add validation",
      "  if (x < 0) throw new Error();",
      "  return x + y;",
      "  // trailing",
      "}",
    ]);
  });

  test("extracts context before and after changes", () => {
    const hunkDiff = `@@ -1,5 +1,5 @@
 before1
 before2
-old
+new
 after1
 after2`;

    const result = extractHunkContent(hunkDiff);

    expect(result.context.before).toEqual(["before1", "before2"]);
    expect(result.context.after).toEqual(["after1", "after2"]);
  });

  test("handles pure addition (no removed lines)", () => {
    const hunkDiff = `@@ -1,2 +1,4 @@
 existing1
+added1
+added2
 existing2`;

    const result = extractHunkContent(hunkDiff);

    expect(result.original).toEqual(["existing1", "existing2"]);
    expect(result.modified).toEqual(["existing1", "added1", "added2", "existing2"]);
  });

  test("handles pure deletion (no added lines)", () => {
    const hunkDiff = `@@ -1,4 +1,2 @@
 existing1
-removed1
-removed2
 existing2`;

    const result = extractHunkContent(hunkDiff);

    expect(result.original).toEqual(["existing1", "removed1", "removed2", "existing2"]);
    expect(result.modified).toEqual(["existing1", "existing2"]);
  });

  test("handles no newline at end of file", () => {
    const hunkDiff = `@@ -1,2 +1,2 @@
 line1
-line2
\\ No newline at end of file
+line2 modified
\\ No newline at end of file`;

    const result = extractHunkContent(hunkDiff);

    expect(result.original).toEqual(["line1", "line2"]);
    expect(result.modified).toEqual(["line1", "line2 modified"]);
  });
});
