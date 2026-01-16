/**
 * Type definitions for the suggestion-manager plugin
 * Based on the protocol specification in DESIGN.md
 */

// ============================================
// Core Types
// ============================================

/**
 * A single hunk from a unified diff
 */
export interface Hunk {
  /** Unique hunk ID within suggestion (format: "suggestion-id:file:hunk-index") */
  id: string;
  /** Relative file path */
  file: string;
  /** Unified diff format for this hunk (includes @@ line numbers, context, +/- lines) */
  diff: string;
}

/**
 * A suggestion containing one or more hunks for review
 */
export interface Suggestion {
  /** Unique suggestion ID (UUID) */
  id: string;
  /** jj change ID for this suggestion */
  jjChangeId: string;
  /** Human-readable description of changes */
  description: string;
  /** List of affected file paths */
  files: string[];
  /** The actual changes, broken into hunks */
  hunks: Hunk[];
  /** Current status of the suggestion */
  status: SuggestionStatus;
  /** Timestamp when suggestion was created */
  createdAt: number;
  /** Review state for each hunk */
  hunkStates: Map<string, HunkState>;
}

export type SuggestionStatus = "pending" | "partial" | "complete" | "discarded";

export interface HunkState {
  reviewed: boolean;
  action?: "accepted" | "rejected" | "modified";
  modifiedDiff?: string;
  comment?: string;
  appliedAt?: number;
}

// ============================================
// Event Types (Sandbox -> User Editor via SSE)
// ============================================

export interface SuggestionReadyEvent {
  type: "suggestion.ready";
  suggestion: {
    id: string;
    jjChangeId: string;
    description: string;
    files: string[];
    hunks: Hunk[];
  };
}

export interface SuggestionErrorEvent {
  type: "suggestion.error";
  code: "experiment_failed" | "sync_failed" | "jj_error" | "apply_failed" | "unknown";
  message: string;
  suggestionId?: string;
  hunkId?: string;
}

export interface SuggestionStatusEvent {
  type: "suggestion.status";
  suggestionId?: string;
  status: "working" | "testing" | "ready" | "applying" | "applied" | "partial";
  message: string;
}

export interface SuggestionHunkAppliedEvent {
  type: "suggestion.hunk_applied";
  suggestionId: string;
  hunkId: string;
  action: "accepted" | "modified" | "rejected";
}

export interface SuggestionListEvent {
  type: "suggestion.list";
  suggestions: Array<{
    id: string;
    jjChangeId: string;
    description: string;
    files: string[];
    hunkCount: number;
    reviewedCount: number;
    status: SuggestionStatus;
  }>;
}

export type SuggestionEvent =
  | SuggestionReadyEvent
  | SuggestionErrorEvent
  | SuggestionStatusEvent
  | SuggestionHunkAppliedEvent
  | SuggestionListEvent;

// ============================================
// Feedback Types (User Editor -> Sandbox)
// ============================================

export interface HunkFeedback {
  suggestionId: string;
  hunkId: string;
  action: "accept" | "reject" | "modify";
  modifiedDiff?: string;
  comment?: string;
}

export interface SuggestionComplete {
  suggestionId: string;
  action: "finalize" | "discard";
}

// ============================================
// Feedback Log Entry (for JSONL logging)
// ============================================

export interface FeedbackLogEntry {
  timestamp: number;
  suggestionId: string;
  hunkId: string;
  action: "accept" | "reject" | "modify";
  file: string;
  originalDiff: string;
  modifiedDiff?: string;
  comment?: string;
  applied: boolean;
}

// ============================================
// Tool Return Types
// ============================================

export interface PublishSuggestionResult {
  suggestionId: string;
  hunkCount: number;
  files: string[];
}

export interface FeedbackResult {
  success: boolean;
  applied: boolean;
  reverted?: boolean;
  remainingHunks: number;
  error?: string;
}

export interface ListSuggestionsResult {
  suggestions: Array<{
    id: string;
    jjChangeId: string;
    description: string;
    files: string[];
    hunkCount: number;
    reviewedCount: number;
    status: SuggestionStatus;
  }>;
}
