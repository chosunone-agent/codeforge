/**
 * Suggestion state management with SQLite persistence
 * Stores and manages pending suggestions and their review state
 */

import { Database } from "bun:sqlite";
import type {
  Suggestion,
  Hunk,
  HunkState,
  HunkFeedback,
  FeedbackLogEntry,
  ListSuggestionsResult,
} from "./types.ts";

/**
 * SQLite-backed store for suggestions
 * Persists suggestions across restarts
 */
export class SuggestionStore {
  private db: Database;
  private feedbackLogPath?: string;
  private dbPath: string;
  private isHealthy: boolean;

  constructor(options?: { dbPath?: string; feedbackLogPath?: string }) {
    const dbPath = options?.dbPath ?? ".opencode/codeforge.db";
    this.dbPath = dbPath;
    this.feedbackLogPath = options?.feedbackLogPath;
    this.isHealthy = false;
    
    try {
      // Validate dbPath - reject empty paths or paths with double slashes
      if (!dbPath || dbPath.trim() === "") {
        throw new Error(`Invalid database path: "${dbPath}"`);
      }
      if (dbPath.includes("//")) {
        throw new Error(`Invalid database path (contains double slashes): "${dbPath}"`);
      }

      // Check if database file already exists
      const fs = require("fs");
      const dbExists = fs.existsSync(dbPath);

      // Ensure directory exists
      const dir = dbPath.substring(0, dbPath.lastIndexOf("/"));
      if (dir && dir !== "" && dir !== ".") {
        try {
          fs.mkdirSync(dir, { recursive: true });
        } catch (mkdirError) {
          // Directory may already exist or mkdir failed
          const mkdirMsg = mkdirError instanceof Error ? mkdirError.message : String(mkdirError);
          console.warn(`[SuggestionStore] Could not create directory ${dir}: ${mkdirMsg}`);
        }
      }
      
      this.db = new Database(dbPath);
      this.initSchema();
      this.cleanupCompletedSuggestions();
      this.isHealthy = true;
      
      if (dbExists) {
        console.log(`[SuggestionStore] Opened existing database at ${dbPath}`);
      } else {
        console.log(`[SuggestionStore] Created new database at ${dbPath}`);
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      console.error(`[SuggestionStore] Failed to initialize database at ${dbPath}:`, errorMsg);
      throw new Error(`Database initialization failed: ${errorMsg}`);
    }
  }

  /**
   * Check if the database is healthy and accessible
   */
  isDbHealthy(): boolean {
    return this.isHealthy;
  }

  /**
   * Get the database path for debugging
   */
  getDbPath(): string {
    return this.dbPath;
  }

  /**
   * Initialize database schema
   */
  private initSchema(): void {
    try {
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS suggestions (
          id TEXT PRIMARY KEY,
          jj_change_id TEXT NOT NULL,
          description TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at INTEGER NOT NULL,
          working_directory TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS hunks (
          id TEXT PRIMARY KEY,
          suggestion_id TEXT NOT NULL,
          file TEXT NOT NULL,
          diff TEXT NOT NULL,
          original_start_line INTEGER,
          original_lines TEXT,
          FOREIGN KEY (suggestion_id) REFERENCES suggestions(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS hunk_states (
          hunk_id TEXT PRIMARY KEY,
          suggestion_id TEXT NOT NULL,
          reviewed INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (hunk_id) REFERENCES hunks(id) ON DELETE CASCADE,
          FOREIGN KEY (suggestion_id) REFERENCES suggestions(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS feedback_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp INTEGER NOT NULL,
          suggestion_id TEXT NOT NULL,
          hunk_id TEXT NOT NULL,
          action TEXT NOT NULL,
          file TEXT NOT NULL,
          original_diff TEXT,
          modified_diff TEXT,
          comment TEXT,
          applied INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_hunks_suggestion ON hunks(suggestion_id);
        CREATE INDEX IF NOT EXISTS idx_hunk_states_suggestion ON hunk_states(suggestion_id);
      `);
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      console.error(`[SuggestionStore] Failed to initialize database schema:`, errorMsg);
      throw new Error(`Database schema initialization failed: ${errorMsg}`);
    }
  }

  /**
   * Clean up completed suggestions on startup
   */
  private cleanupCompletedSuggestions(): void {
    // Remove suggestions with no remaining hunks
    this.db.exec(`
      DELETE FROM suggestions 
      WHERE id NOT IN (SELECT DISTINCT suggestion_id FROM hunks)
    `);
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
    const createdAt = Date.now();

    // Insert suggestion
    this.db.run(
      `INSERT INTO suggestions (id, jj_change_id, description, status, created_at, working_directory)
       VALUES (?, ?, ?, 'pending', ?, ?)`,
      [params.id, params.jjChangeId, params.description, createdAt, params.workingDirectory]
    );

    // Insert hunks and their states
    const insertHunk = this.db.prepare(
      `INSERT INTO hunks (id, suggestion_id, file, diff, original_start_line, original_lines)
       VALUES (?, ?, ?, ?, ?, ?)`
    );
    const insertState = this.db.prepare(
      `INSERT INTO hunk_states (hunk_id, suggestion_id, reviewed)
       VALUES (?, ?, 0)`
    );

    for (const hunk of params.hunks) {
      insertHunk.run(
        hunk.id,
        params.id,
        hunk.file,
        hunk.diff,
        hunk.originalStartLine ?? null,
        hunk.originalLines ? JSON.stringify(hunk.originalLines) : null
      );
      insertState.run(hunk.id, params.id);
    }

    return this.getSuggestion(params.id)!;
  }

  /**
   * Get a suggestion by ID
   */
  getSuggestion(id: string): Suggestion | undefined {
    const row = this.db.query(
      `SELECT id, jj_change_id, description, status, created_at, working_directory
       FROM suggestions WHERE id = ?`
    ).get(id) as {
      id: string;
      jj_change_id: string;
      description: string;
      status: string;
      created_at: number;
      working_directory: string;
    } | null;

    if (!row) return undefined;

    // Get hunks
    const hunkRows = this.db.query(
      `SELECT id, file, diff, original_start_line, original_lines
       FROM hunks WHERE suggestion_id = ?`
    ).all(id) as Array<{
      id: string;
      file: string;
      diff: string;
      original_start_line: number | null;
      original_lines: string | null;
    }>;

    const hunks: Hunk[] = hunkRows.map((h) => ({
      id: h.id,
      suggestionId: id,
      file: h.file,
      diff: h.diff,
      originalStartLine: h.original_start_line ?? undefined,
      originalLines: h.original_lines ? JSON.parse(h.original_lines) : undefined,
    }));

    // Get hunk states
    const stateRows = this.db.query(
      `SELECT hunk_id, reviewed FROM hunk_states WHERE suggestion_id = ?`
    ).all(id) as Array<{ hunk_id: string; reviewed: number }>;

    const hunkStates = new Map<string, HunkState>();
    for (const s of stateRows) {
      hunkStates.set(s.hunk_id, { reviewed: s.reviewed === 1 });
    }

    // Get unique files from hunks
    const files = [...new Set(hunks.map((h) => h.file))];

    return {
      id: row.id,
      jjChangeId: row.jj_change_id,
      description: row.description,
      files,
      hunks,
      status: row.status as Suggestion["status"],
      createdAt: row.created_at,
      hunkStates,
      workingDirectory: row.working_directory,
    };
  }

  /**
   * Get a hunk by ID
   */
  getHunk(suggestionId: string, hunkId: string): Hunk | undefined {
    const row = this.db.query(
      `SELECT id, file, diff, original_start_line, original_lines
       FROM hunks WHERE id = ? AND suggestion_id = ?`
    ).get(hunkId, suggestionId) as {
      id: string;
      file: string;
      diff: string;
      original_start_line: number | null;
      original_lines: string | null;
    } | null;

    if (!row) return undefined;

    return {
      id: row.id,
      file: row.file,
      diff: row.diff,
      originalStartLine: row.original_start_line ?? undefined,
      originalLines: row.original_lines ? JSON.parse(row.original_lines) : undefined,
    };
  }

  /**
   * Get hunk state
   */
  getHunkState(suggestionId: string, hunkId: string): HunkState | undefined {
    const row = this.db.query(
      `SELECT reviewed FROM hunk_states WHERE hunk_id = ? AND suggestion_id = ?`
    ).get(hunkId, suggestionId) as { reviewed: number } | null;

    if (!row) return undefined;
    return { reviewed: row.reviewed === 1 };
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
    const hunk = this.getHunk(suggestionId, hunkId);
    if (!hunk) return false;

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

    // Remove the hunk and its state
    this.db.run(`DELETE FROM hunk_states WHERE hunk_id = ?`, [hunkId]);
    this.db.run(`DELETE FROM hunks WHERE id = ?`, [hunkId]);

    // Update suggestion status
    const remainingCount = this.getRemainingCount(suggestionId);
    const newStatus = remainingCount === 0 ? "complete" : "partial";
    this.db.run(`UPDATE suggestions SET status = ? WHERE id = ?`, [newStatus, suggestionId]);

    return true;
  }

  /**
   * Get count of remaining (pending) hunks
   */
  getRemainingCount(suggestionId: string): number {
    const row = this.db.query(
      `SELECT COUNT(*) as count FROM hunks WHERE suggestion_id = ?`
    ).get(suggestionId) as { count: number };
    return row?.count ?? 0;
  }

  /**
   * List all suggestions, optionally filtered by working directory
   * Only returns suggestions with pending hunks
   */
  listSuggestions(workingDirectory?: string): ListSuggestionsResult {
    let query = `
      SELECT s.id, s.jj_change_id, s.description, s.status, s.created_at, s.working_directory,
             COUNT(h.id) as hunk_count
      FROM suggestions s
      LEFT JOIN hunks h ON h.suggestion_id = s.id
      GROUP BY s.id
      HAVING hunk_count > 0
    `;
    const params: string[] = [];

    if (workingDirectory) {
      query = `
        SELECT s.id, s.jj_change_id, s.description, s.status, s.created_at, s.working_directory,
               COUNT(h.id) as hunk_count
        FROM suggestions s
        LEFT JOIN hunks h ON h.suggestion_id = s.id
        WHERE s.working_directory = ? 
           OR s.working_directory LIKE '%/' || ?
           OR ? LIKE '%/' || s.working_directory
        GROUP BY s.id
        HAVING hunk_count > 0
      `;
      params.push(workingDirectory, workingDirectory, workingDirectory);
    }

    query += ` ORDER BY s.created_at DESC`;

    const rows = this.db.query(query).all(...params) as Array<{
      id: string;
      jj_change_id: string;
      description: string;
      status: string;
      created_at: number;
      working_directory: string;
      hunk_count: number;
    }>;

    const suggestions = rows.map((row) => {
      // Get unique files for this suggestion
      const fileRows = this.db.query(
        `SELECT DISTINCT file FROM hunks WHERE suggestion_id = ?`
      ).all(row.id) as Array<{ file: string }>;
      
      return {
        id: row.id,
        jjChangeId: row.jj_change_id,
        description: row.description,
        files: fileRows.map((f) => f.file),
        hunkCount: row.hunk_count,
        reviewedCount: 0, // Hunks are removed when reviewed
        status: row.status as Suggestion["status"],
        workingDirectory: row.working_directory,
      };
    });

    return { suggestions };
  }

  /**
   * Mark suggestion as discarded
   */
  discardSuggestion(suggestionId: string): boolean {
    const result = this.db.run(
      `UPDATE suggestions SET status = 'discarded' WHERE id = ?`,
      [suggestionId]
    );
    return result.changes > 0;
  }

  /**
   * Remove a suggestion from the store
   */
  removeSuggestion(suggestionId: string): boolean {
    // Hunks and states will be cascade deleted
    const result = this.db.run(`DELETE FROM suggestions WHERE id = ?`, [suggestionId]);
    return result.changes > 0;
  }

  /**
   * Log feedback entry
   */
  private logFeedback(entry: FeedbackLogEntry): void {
    this.db.run(
      `INSERT INTO feedback_log (timestamp, suggestion_id, hunk_id, action, file, original_diff, modified_diff, comment, applied)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        entry.timestamp,
        entry.suggestionId,
        entry.hunkId,
        entry.action,
        entry.file,
        entry.originalDiff ?? null,
        entry.modifiedDiff ?? null,
        entry.comment ?? null,
        entry.applied ? 1 : 0,
      ]
    );

    // Also append to JSONL file if configured
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
      const existing = (await file.exists()) ? await file.text() : "";
      await Bun.write(this.feedbackLogPath, existing + line);
    } catch (error) {
      console.error("Failed to write feedback log:", error);
    }
  }

  /**
   * Get all feedback entries (for testing/debugging)
   */
  getFeedbackLog(): FeedbackLogEntry[] {
    const rows = this.db.query(
      `SELECT timestamp, suggestion_id, hunk_id, action, file, original_diff, modified_diff, comment, applied
       FROM feedback_log ORDER BY timestamp`
    ).all() as Array<{
      timestamp: number;
      suggestion_id: string;
      hunk_id: string;
      action: string;
      file: string;
      original_diff: string | null;
      modified_diff: string | null;
      comment: string | null;
      applied: number;
    }>;

    return rows.map((row) => ({
      timestamp: row.timestamp,
      suggestionId: row.suggestion_id,
      hunkId: row.hunk_id,
      action: row.action as "accept" | "reject" | "modify",
      file: row.file,
      originalDiff: row.original_diff ?? undefined,
      modifiedDiff: row.modified_diff ?? undefined,
      comment: row.comment ?? undefined,
      applied: row.applied === 1,
    }));
  }

  /**
   * Clear all suggestions (for testing)
   */
  clear(): void {
    this.db.exec(`DELETE FROM hunk_states`);
    this.db.exec(`DELETE FROM hunks`);
    this.db.exec(`DELETE FROM suggestions`);
    this.db.exec(`DELETE FROM feedback_log`);
  }

  /**
   * Close the database connection
   */
  close(): void {
    this.db.close();
  }
}

/**
 * Generate a unique suggestion ID
 */
export function generateSuggestionId(): string {
  return crypto.randomUUID();
}
