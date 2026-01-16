/**
 * Unified diff parser
 * Parses output from `jj diff` or `git diff` into structured hunks
 */

import type { Hunk } from "./types.ts";

/**
 * Parsed file diff containing all hunks for a single file
 */
export interface FileDiff {
  /** Original file path (a/ side) */
  oldPath: string;
  /** New file path (b/ side) */
  newPath: string;
  /** All hunks in this file */
  hunks: ParsedHunk[];
}

/**
 * A parsed hunk with metadata extracted from the @@ line
 */
export interface ParsedHunk {
  /** Starting line in original file */
  oldStart: number;
  /** Number of lines in original */
  oldCount: number;
  /** Starting line in new file */
  newStart: number;
  /** Number of lines in new file */
  newCount: number;
  /** Optional function/context from @@ line */
  context?: string;
  /** The full hunk text including @@ header */
  content: string;
}

/**
 * Parse a complete unified diff output into file diffs
 */
export function parseDiff(diffText: string): FileDiff[] {
  const files: FileDiff[] = [];
  const lines = diffText.split("\n");

  let currentFile: FileDiff | null = null;
  let currentHunk: string[] = [];
  let currentHunkMeta: Omit<ParsedHunk, "content"> | null = null;

  const flushHunk = () => {
    if (currentFile && currentHunkMeta && currentHunk.length > 0) {
      currentFile.hunks.push({
        ...currentHunkMeta,
        content: currentHunk.join("\n"),
      });
    }
    currentHunk = [];
    currentHunkMeta = null;
  };

  const flushFile = () => {
    flushHunk();
    if (currentFile) {
      files.push(currentFile);
    }
    currentFile = null;
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;

    // New file header: diff --git a/path b/path
    // or: diff -r ... (for jj)
    if (line.startsWith("diff --git ") || line.startsWith("diff -r ")) {
      flushFile();

      // Extract paths from diff line
      const paths = extractPathsFromDiffLine(line);
      currentFile = {
        oldPath: paths.oldPath,
        newPath: paths.newPath,
        hunks: [],
      };
      continue;
    }

    // --- a/path or --- /dev/null
    if (line.startsWith("--- ")) {
      if (currentFile) {
        const path = line.slice(4).trim();
        // Handle "--- a/path" format
        currentFile.oldPath = path.startsWith("a/") ? path.slice(2) : path;
      }
      continue;
    }

    // +++ b/path or +++ /dev/null
    if (line.startsWith("+++ ")) {
      if (currentFile) {
        const path = line.slice(4).trim();
        // Handle "+++ b/path" format
        currentFile.newPath = path.startsWith("b/") ? path.slice(2) : path;
      }
      continue;
    }

    // Hunk header: @@ -start,count +start,count @@ optional context
    if (line.startsWith("@@")) {
      flushHunk();

      const hunkMeta = parseHunkHeader(line);
      if (hunkMeta) {
        currentHunkMeta = hunkMeta;
        currentHunk.push(line);
      }
      continue;
    }

    // Hunk content: lines starting with space, +, -, or \
    if (currentHunkMeta && (line.startsWith(" ") || line.startsWith("+") || line.startsWith("-") || line.startsWith("\\"))) {
      currentHunk.push(line);
      continue;
    }

    // Empty line within a hunk (context line)
    if (currentHunkMeta && line === "") {
      currentHunk.push(line);
      continue;
    }
  }

  // Flush any remaining content
  flushFile();

  return files;
}

/**
 * Extract file paths from a diff header line
 */
function extractPathsFromDiffLine(line: string): { oldPath: string; newPath: string } {
  // diff --git a/path/to/file b/path/to/file
  const gitMatch = line.match(/^diff --git a\/(.+) b\/(.+)$/);
  if (gitMatch) {
    return { oldPath: gitMatch[1]!, newPath: gitMatch[2]! };
  }

  // diff -r <hash> <hash> path/to/file (jj format)
  const jjMatch = line.match(/^diff -r [a-f0-9]+ [a-f0-9]+ (.+)$/);
  if (jjMatch) {
    return { oldPath: jjMatch[1]!, newPath: jjMatch[1]! };
  }

  // Fallback: try to extract anything after the command
  const parts = line.split(" ");
  const lastPart = parts[parts.length - 1] ?? "";
  return { oldPath: lastPart, newPath: lastPart };
}

/**
 * Parse a hunk header line (@@ -start,count +start,count @@ context)
 */
export function parseHunkHeader(line: string): Omit<ParsedHunk, "content"> | null {
  // @@ -10,7 +10,9 @@ function example()
  const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/);
  if (!match) {
    return null;
  }

  return {
    oldStart: parseInt(match[1]!, 10),
    oldCount: match[2] ? parseInt(match[2], 10) : 1,
    newStart: parseInt(match[3]!, 10),
    newCount: match[4] ? parseInt(match[4], 10) : 1,
    context: match[5]?.trim() || undefined,
  };
}

/**
 * Convert parsed file diffs into Hunk objects for a suggestion
 */
export function fileDiffsToHunks(fileDiffs: FileDiff[], suggestionId: string): Hunk[] {
  const hunks: Hunk[] = [];

  for (const fileDiff of fileDiffs) {
    for (let i = 0; i < fileDiff.hunks.length; i++) {
      const parsedHunk = fileDiff.hunks[i]!;
      const { original } = extractHunkContent(parsedHunk.content);
      
      hunks.push({
        id: `${suggestionId}:${fileDiff.newPath}:${i}`,
        file: fileDiff.newPath,
        diff: parsedHunk.content,
        originalLines: original,
        originalStartLine: parsedHunk.oldStart,
      });
    }
  }

  return hunks;
}

/**
 * Filter options for selective publishing
 */
export interface FilterOptions {
  /** File paths or glob patterns to include (if empty, includes all) */
  includeFiles?: string[];
  /** File paths or glob patterns to exclude */
  excludeFiles?: string[];
  /** Filter hunks by line range within a specific file */
  lineRanges?: {
    file: string;
    startLine: number;
    endLine: number;
  }[];
}

/**
 * Check if a file path matches any of the given patterns
 * Supports exact matches and simple glob patterns (* and **)
 */
function matchesPattern(filePath: string, patterns: string[]): boolean {
  for (const pattern of patterns) {
    // Exact match
    if (filePath === pattern) {
      return true;
    }
    
    // Convert glob pattern to regex
    const regexPattern = pattern
      .replace(/\*\*/g, "{{GLOBSTAR}}")  // Temporarily replace **
      .replace(/\*/g, "[^/]*")            // * matches anything except /
      .replace(/{{GLOBSTAR}}/g, ".*")     // ** matches anything including /
      .replace(/\?/g, ".");               // ? matches single character
    
    const regex = new RegExp(`^${regexPattern}$`);
    if (regex.test(filePath)) {
      return true;
    }
  }
  return false;
}

/**
 * Filter file diffs based on include/exclude patterns
 */
export function filterFileDiffs(fileDiffs: FileDiff[], options: FilterOptions): FileDiff[] {
  let filtered = fileDiffs;
  
  // Filter by include patterns (if specified)
  if (options.includeFiles && options.includeFiles.length > 0) {
    filtered = filtered.filter(fd => 
      matchesPattern(fd.newPath, options.includeFiles!) ||
      matchesPattern(fd.oldPath, options.includeFiles!)
    );
  }
  
  // Filter by exclude patterns
  if (options.excludeFiles && options.excludeFiles.length > 0) {
    filtered = filtered.filter(fd => 
      !matchesPattern(fd.newPath, options.excludeFiles!) &&
      !matchesPattern(fd.oldPath, options.excludeFiles!)
    );
  }
  
  // Filter hunks by line ranges
  if (options.lineRanges && options.lineRanges.length > 0) {
    filtered = filtered.map(fd => {
      const rangesForFile = options.lineRanges!.filter(
        r => r.file === fd.newPath || r.file === fd.oldPath
      );
      
      if (rangesForFile.length === 0) {
        // No line range filter for this file, keep all hunks
        return fd;
      }
      
      // Filter hunks to only those overlapping with specified line ranges
      const filteredHunks = fd.hunks.filter(hunk => {
        const hunkStart = hunk.newStart;
        const hunkEnd = hunk.newStart + hunk.newCount - 1;
        
        return rangesForFile.some(range => 
          // Hunk overlaps with range
          hunkStart <= range.endLine && hunkEnd >= range.startLine
        );
      });
      
      return {
        ...fd,
        hunks: filteredHunks,
      };
    }).filter(fd => fd.hunks.length > 0); // Remove files with no hunks
  }
  
  return filtered;
}

/**
 * Get unique file paths from a diff
 */
export function getFilesFromDiff(diffText: string): string[] {
  const fileDiffs = parseDiff(diffText);
  const files = new Set<string>();

  for (const fileDiff of fileDiffs) {
    // Use newPath as the canonical path (handles renames)
    if (fileDiff.newPath && fileDiff.newPath !== "/dev/null") {
      files.add(fileDiff.newPath);
    } else if (fileDiff.oldPath && fileDiff.oldPath !== "/dev/null") {
      files.add(fileDiff.oldPath);
    }
  }

  return Array.from(files);
}

/**
 * Extract the original and modified content from a hunk diff
 * Useful for applying patches or displaying side-by-side
 */
export function extractHunkContent(hunkDiff: string): {
  original: string[];
  modified: string[];
  context: { before: string[]; after: string[] };
} {
  const lines = hunkDiff.split("\n");
  const original: string[] = [];
  const modified: string[] = [];
  const contextBefore: string[] = [];
  const contextAfter: string[] = [];

  let seenChange = false;
  let afterChange = false;

  for (const line of lines) {
    // Skip the @@ header
    if (line.startsWith("@@")) {
      continue;
    }

    // Context line (space prefix)
    if (line.startsWith(" ")) {
      const content = line.slice(1);
      original.push(content);
      modified.push(content);

      if (!seenChange) {
        contextBefore.push(content);
      } else {
        afterChange = true;
        contextAfter.push(content);
      }
      continue;
    }

    // Removed line
    if (line.startsWith("-")) {
      seenChange = true;
      afterChange = false;
      contextAfter.length = 0; // Reset after context
      original.push(line.slice(1));
      continue;
    }

    // Added line
    if (line.startsWith("+")) {
      seenChange = true;
      afterChange = false;
      contextAfter.length = 0; // Reset after context
      modified.push(line.slice(1));
      continue;
    }

    // "\ No newline at end of file" - ignore
    if (line.startsWith("\\")) {
      continue;
    }
  }

  return {
    original,
    modified,
    context: {
      before: contextBefore,
      after: afterChange ? contextAfter : [],
    },
  };
}

/**
 * Calculate the net line offset for a file based on previously applied hunks
 * Positive offset means the file has grown, negative means it has shrunk
 */
export function calculateLineOffset(
  hunks: ParsedHunk[],
  appliedHunkIds: Set<string>,
  filePath: string,
  suggestionId: string
): number {
  let offset = 0;

  for (const hunk of hunks) {
    const hunkId = `${suggestionId}:${filePath}:${hunks.indexOf(hunk)}`;
    
    if (appliedHunkIds.has(hunkId)) {
      // This hunk was applied, calculate its net line change
      const netChange = hunk.newCount - hunk.oldCount;
      offset += netChange;
    }
  }

  return offset;
}

/**
 * Adjust a hunk's line numbers based on the current line offset
 * This is needed when applying hunks sequentially, as previous hunks may have changed the file length
 */
export function adjustHunkLineNumbers(hunkDiff: string, lineOffset: number): string {
  const lines = hunkDiff.split("\n");
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line?.startsWith("@@")) {
      const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/);
      if (match) {
        const oldStart = parseInt(match[1]!, 10);
        const oldCount = match[2] ? parseInt(match[2]!, 10) : 1;
        const newStart = parseInt(match[3]!, 10);
        const newCount = match[4] ? parseInt(match[4]!, 10) : 1;
        const context = match[5] ?? "";
        
        // Adjust the new start line by the offset
        const adjustedNewStart = newStart + lineOffset;
        
        lines[i] = `@@ -${oldStart}${oldCount > 1 ? `,${oldCount}` : ""} +${adjustedNewStart}${newCount > 1 ? `,${newCount}` : ""} @@${context}`;
      }
    }
  }
  
  return lines.join("\n");
}
