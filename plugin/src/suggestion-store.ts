/**
 * Suggestion state management
 * Stores and manages pending suggestions and their review state
 */

import type {
  Suggestion,
  Hunk,
  HunkState,
  HunkFeedback,
  FeedbackLogEntry,
  ListSuggestionsResult,
} from "./types.ts";

/**
 * In-memory store for suggestions
 * In production, this could be persisted to disk
 */
export class SuggestionStore {
  private suggestions: Map<string, Suggestion> = new Map();
  private feedbackLog: FeedbackLogEntry[] = [];
  private feedbackLogPath?: string;

  constructor(options?: { feedbackLogPath?: string }) {
    this.feedbackLogPath = options?.feedbackLogPath;
  }

  /**
   * Create a new suggestion
   */
  createSuggestion(params: {
    id: string;
    jjChangeId: string;
    description: string;
    files: string[];
    hunks: Hunk[];
    workingDirectory: string;
  }): Suggestion {
    const suggestion: Suggestion = {
      id: params.id,
      jjChangeId: params.jjChangeId,
      description: params.description,
      files: params.files,
      hunks: params.hunks,
      status: "pending",
      createdAt: Date.now(),
      hunkStates: new Map(),
      workingDirectory: params.workingDirectory,
    };

    // Initialize hunk states
    for (const hunk of params.hunks) {
      suggestion.hunkStates.set(hunk.id, { reviewed: false });
    }

    this.suggestions.set(params.id, suggestion);
    return suggestion;
  }

  /**
   * Get a suggestion by ID
   */
  getSuggestion(id: string): Suggestion | undefined {
    return this.suggestions.get(id);
  }

  /**
   * Get a hunk by ID
   */
  getHunk(suggestionId: string, hunkId: string): Hunk | undefined {
    const suggestion = this.suggestions.get(suggestionId);
    if (!suggestion) return undefined;
    return suggestion.hunks.find((h) => h.id === hunkId);
  }

  /**
   * Get hunk state
   */
  getHunkState(suggestionId: string, hunkId: string): HunkState | undefined {
    const suggestion = this.suggestions.get(suggestionId);
    if (!suggestion) return undefined;
    return suggestion.hunkStates.get(hunkId);
  }

  /**
   * Update hunk state after feedback and remove the hunk from the suggestion
   */
  updateHunkState(
    suggestionId: string,
    hunkId: string,
    feedback: HunkFeedback,
    applied: boolean
  ): boolean {
    const suggestion = this.suggestions.get(suggestionId);
    if (!suggestion) return false;

    const hunkIndex = suggestion.hunks.findIndex((h) => h.id === hunkId);
    if (hunkIndex === -1) return false;
    
    const hunk = suggestion.hunks[hunkIndex];

    // Log feedback before removing
    this.logFeedback({
      timestamp: Date.now(),
      suggestionId,
      hunkId,
      action: feedback.action,
      file: hunk.file,
      originalDiff: hunk.diff,
      modifiedDiff: feedback.modifiedDiff,
      comment: feedback.comment,
      applied,
    });

    // Remove the hunk from the suggestion
    suggestion.hunks.splice(hunkIndex, 1);
    suggestion.hunkStates.delete(hunkId);
    
    // Update files list (remove file if no more hunks reference it)
    const remainingFiles = new Set(suggestion.hunks.map(h => h.file));
    suggestion.files = suggestion.files.filter(f => remainingFiles.has(f));

    // Update suggestion status
    if (suggestion.hunks.length === 0) {
      suggestion.status = "complete";
    } else {
      suggestion.status = "partial";
    }

    return true;
  }

  /**
   * Get count of remaining (pending) hunks
   */
  getRemainingCount(suggestionId: string): number {
    const suggestion = this.suggestions.get(suggestionId);
    if (!suggestion) return 0;

    return suggestion.hunks.length;
  }

  /**
   * List all suggestions, optionally filtered by working directory
   * Only returns suggestions with pending hunks
   */
  listSuggestions(workingDirectory?: string): ListSuggestionsResult {
    const suggestions: ListSuggestionsResult["suggestions"] = [];

    for (const suggestion of this.suggestions.values()) {
      // Skip suggestions with no remaining hunks
      if (suggestion.hunks.length === 0) {
        continue;
      }
      
      // Filter by working directory if specified
      // Match if either ends with the other (handles relative vs absolute paths)
      if (workingDirectory && suggestion.workingDirectory) {
        const suggestionDir = suggestion.workingDirectory;
        const matches = suggestionDir === workingDirectory ||
          suggestionDir.endsWith("/" + workingDirectory) ||
          workingDirectory.endsWith("/" + suggestionDir);
        if (!matches) {
          continue;
        }
      }
      
      suggestions.push({
        id: suggestion.id,
        jjChangeId: suggestion.jjChangeId,
        description: suggestion.description,
        files: suggestion.files,
        hunkCount: suggestion.hunks.length,
        reviewedCount: 0, // Hunks are removed when reviewed, so remaining = hunkCount
        status: suggestion.status,
        workingDirectory: suggestion.workingDirectory,
      });
    }

    // Sort by creation time, newest first
    suggestions.sort((a, b) => {
      const suggA = this.suggestions.get(a.id);
      const suggB = this.suggestions.get(b.id);
      return (suggB?.createdAt ?? 0) - (suggA?.createdAt ?? 0);
    });

    return { suggestions };
  }

  /**
   * Mark suggestion as discarded
   */
  discardSuggestion(suggestionId: string): boolean {
    const suggestion = this.suggestions.get(suggestionId);
    if (!suggestion) return false;

    suggestion.status = "discarded";
    return true;
  }

  /**
   * Remove a suggestion from the store
   */
  removeSuggestion(suggestionId: string): boolean {
    return this.suggestions.delete(suggestionId);
  }

  /**
   * Log feedback entry
   */
  private logFeedback(entry: FeedbackLogEntry): void {
    this.feedbackLog.push(entry);

    // If we have a log path, append to file
    if (this.feedbackLogPath) {
      this.appendToFeedbackLog(entry);
    }
  }

  /**
   * Append feedback entry to JSONL file
   */
  private async appendToFeedbackLog(entry: FeedbackLogEntry): Promise<void> {
    if (!this.feedbackLogPath) return;

    try {
      const line = JSON.stringify(entry) + "\n";
      const file = Bun.file(this.feedbackLogPath);
      const existing = await file.exists() ? await file.text() : "";
      await Bun.write(this.feedbackLogPath, existing + line);
    } catch (error) {
      console.error("Failed to write feedback log:", error);
    }
  }

  /**
   * Get all feedback entries (for testing/debugging)
   */
  getFeedbackLog(): FeedbackLogEntry[] {
    return [...this.feedbackLog];
  }

  /**
   * Clear all suggestions (for testing)
   */
  clear(): void {
    this.suggestions.clear();
    this.feedbackLog = [];
  }
}

/**
 * Generate a unique suggestion ID
 */
export function generateSuggestionId(): string {
  return crypto.randomUUID();
}
