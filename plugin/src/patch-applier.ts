/**
 * Patch applier for applying unified diff hunks to files
 * 
 * This module handles applying individual hunks from unified diffs
 * to the working copy files.
 */

import { parseHunkHeader } from "./diff-parser.ts";

export interface ApplyResult {
  success: boolean;
  error?: string;
  /** The new file content after applying the patch */
  newContent?: string;
}

/**
 * Apply a unified diff hunk to file content
 * 
 * @param originalContent - The original file content
 * @param hunkDiff - The unified diff hunk (including @@ header)
 * @returns Result with new content or error
 */
export function applyHunk(originalContent: string, hunkDiff: string): ApplyResult {
  const lines = originalContent.split("\n");
  const hunkLines = hunkDiff.split("\n");

  // Parse the hunk header
  const headerLine = hunkLines[0];
  if (!headerLine?.startsWith("@@")) {
    return { success: false, error: "Invalid hunk: missing @@ header" };
  }

  const header = parseHunkHeader(headerLine);
  if (!header) {
    return { success: false, error: "Invalid hunk: could not parse @@ header" };
  }

  // Extract the changes from the hunk
  const changes: Array<{ type: "context" | "add" | "remove"; content: string }> = [];
  
  for (let i = 1; i < hunkLines.length; i++) {
    const line = hunkLines[i];
    if (line === undefined) continue;

    if (line.startsWith(" ")) {
      changes.push({ type: "context", content: line.slice(1) });
    } else if (line.startsWith("+")) {
      changes.push({ type: "add", content: line.slice(1) });
    } else if (line.startsWith("-")) {
      changes.push({ type: "remove", content: line.slice(1) });
    } else if (line.startsWith("\\")) {
      // "\ No newline at end of file" - skip
      continue;
    } else if (line === "") {
      // Empty line in diff could be empty context line
      changes.push({ type: "context", content: "" });
    }
  }

  // Apply the changes
  // Start position is 0-indexed (header.oldStart is 1-indexed)
  const startIndex = header.oldStart - 1;

  // Verify context lines match (with some fuzz tolerance)
  const verifyResult = verifyContext(lines, changes, startIndex);
  if (!verifyResult.success) {
    return { success: false, error: verifyResult.error };
  }

  // Build the new content
  const result: string[] = [];

  // Add lines before the hunk
  for (let i = 0; i < startIndex; i++) {
    result.push(lines[i]!);
  }

  // Apply the hunk changes
  let originalIndex = startIndex;
  for (const change of changes) {
    if (change.type === "context") {
      result.push(lines[originalIndex]!);
      originalIndex++;
    } else if (change.type === "add") {
      result.push(change.content);
    } else if (change.type === "remove") {
      // Skip this line in original
      originalIndex++;
    }
  }

  // Add lines after the hunk
  for (let i = originalIndex; i < lines.length; i++) {
    result.push(lines[i]!);
  }

  return { success: true, newContent: result.join("\n") };
}

/**
 * Verify that context lines in the hunk match the original file
 */
function verifyContext(
  originalLines: string[],
  changes: Array<{ type: "context" | "add" | "remove"; content: string }>,
  startIndex: number
): { success: boolean; error?: string } {
  let originalIndex = startIndex;

  for (const change of changes) {
    if (change.type === "context" || change.type === "remove") {
      const originalLine = originalLines[originalIndex];
      
      if (originalLine === undefined) {
        return {
          success: false,
          error: `Context mismatch: line ${originalIndex + 1} does not exist in file`,
        };
      }

      // Allow some whitespace flexibility
      if (normalizeWhitespace(originalLine) !== normalizeWhitespace(change.content)) {
        return {
          success: false,
          error: `Context mismatch at line ${originalIndex + 1}: expected "${change.content}", got "${originalLine}"`,
        };
      }

      originalIndex++;
    }
  }

  return { success: true };
}

/**
 * Normalize whitespace for comparison (trim trailing whitespace)
 */
function normalizeWhitespace(line: string): string {
  return line.trimEnd();
}

/**
 * Apply a hunk to a file on disk
 */
export async function applyHunkToFile(
  filePath: string,
  hunkDiff: string
): Promise<ApplyResult> {
  try {
    // Read the file
    const file = Bun.file(filePath);
    const exists = await file.exists();
    
    if (!exists) {
      // Check if this is a new file (hunk starts at line 0)
      const header = parseHunkHeader(hunkDiff.split("\n")[0] ?? "");
      if (header?.oldStart === 0 && header?.oldCount === 0) {
        // New file - extract added lines
        const lines = hunkDiff.split("\n").slice(1);
        const content = lines
          .filter((l) => l.startsWith("+"))
          .map((l) => l.slice(1))
          .join("\n");
        
        await Bun.write(filePath, content);
        return { success: true, newContent: content };
      }
      
      return { success: false, error: `File not found: ${filePath}` };
    }

    const originalContent = await file.text();

    // Apply the hunk
    const result = applyHunk(originalContent, hunkDiff);
    
    if (!result.success) {
      return result;
    }

    // Write the new content
    await Bun.write(filePath, result.newContent!);

    return result;
  } catch (error) {
    return {
      success: false,
      error: `Failed to apply hunk: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

/**
 * Apply a modified diff (user-edited version of a hunk)
 */
export async function applyModifiedHunk(
  filePath: string,
  modifiedDiff: string
): Promise<ApplyResult> {
  // Modified diff is applied the same way as original
  return applyHunkToFile(filePath, modifiedDiff);
}

/**
 * Create a reverse hunk (for undoing an applied hunk)
 */
export function reverseHunk(hunkDiff: string): string {
  const lines = hunkDiff.split("\n");
  const result: string[] = [];

  for (const line of lines) {
    if (line.startsWith("@@")) {
      // Swap old and new in header
      const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/);
      if (match) {
        const [, oldStart, oldCount, newStart, newCount, context] = match;
        const newHeader = `@@ -${newStart}${newCount ? `,${newCount}` : ""} +${oldStart}${oldCount ? `,${oldCount}` : ""} @@${context ?? ""}`;
        result.push(newHeader);
      } else {
        result.push(line);
      }
    } else if (line.startsWith("+")) {
      // Added becomes removed
      result.push("-" + line.slice(1));
    } else if (line.startsWith("-")) {
      // Removed becomes added
      result.push("+" + line.slice(1));
    } else {
      // Context and other lines stay the same
      result.push(line);
    }
  }

  return result.join("\n");
}
