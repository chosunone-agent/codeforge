# Isolated AI Coder - Design Document

> **Status**: Work in progress - plugin implemented, neovim integration pending

## Overview

A workflow system that enables an AI coding assistant (running in a sandboxed environment under a separate user) to experiment freely with code changes, then present those changes for interactive, hunk-by-hunk review in the user's editor before applying them to the shared codebase.

## Problem Statement

When working with an AI coding assistant, the current workflow has limitations:
- Changes are applied directly, requiring after-the-fact review
- No sandbox for the AI to experiment, run tests, and iterate before presenting changes
- All-or-nothing acceptance of changes
- Limited feedback loop for the AI to learn from accepted/rejected changes

## Goals

1. Allow the user to request code changes from their editor
2. Give the AI a sandbox environment to experiment and iterate
3. Present changes as reviewable suggestions (hunk-by-hunk)
4. Enable interactive review: accept, reject, or modify each hunk
5. Keep both repositories (user's and sandbox) in sync
6. Provide feedback to the AI about what was accepted/modified/rejected

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            USER'S NEOVIM                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  opencode.nvim + suggestion-review extension                        │    │
│  │  - Connects via WebSocket for real-time bidirectional communication │    │
│  │  - Receives push events (suggestion.ready, hunk_applied, etc.)      │    │
│  │  - Sends commands (feedback, list, get, complete)                   │    │
│  │  - Shows notification when suggestions ready                        │    │
│  │  - Provides hunk-by-hunk review UI                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ WebSocket + HTTP (localhost:4097)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SANDBOX (opencode user)                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  opencode serve                                                     │    │
│  │  + suggestion-manager plugin (HTTP + WebSocket server on :4097)     │    │
│  │    - Provides tools for AI (publish_suggestion, etc.)               │    │
│  │    - WebSocket endpoint (/ws) for real-time client connections      │    │
│  │    - Broadcasts events to all connected clients                     │    │
│  │    - HTTP endpoints for simple testing/debugging                    │    │
│  │    - Receives and logs feedback from user reviews                   │    │
│  │    - Notifies AI via session prompt injection                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  Version Control (jj):                                                      │
│  - Each suggestion = its own jj change node                                 │
│  - `jj diff` provides the hunks for review                                  │
│  - Accepted changes synced to shared repo                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. OpenCode Plugin (Sandbox Side)

**Location:** `~/.config/opencode/plugin/suggestion-manager.ts`

**Responsibilities:**
- Expose `publish_suggestion` tool for AI to call when changes are ready
- Parse jj diff output into structured hunks
- Emit SSE events to notify user's editor
- Receive feedback from user reviews
- Apply accepted changes and sync repositories
- Handle errors and send error notifications

### 2. Neovim Plugin Extension (User Side)

**Location:** Extension to NickvanDyke/opencode.nvim

**Responsibilities:**
- Connect to sandbox opencode server
- Subscribe to SSE event stream
- Display notifications when suggestions are ready
- Provide hunk-by-hunk review interface
- Send feedback (accept/reject/modify) back to sandbox
- Handle errors gracefully

### 3. Shared Git Repository

Both the user and sandbox have clones of the same repository. Sync happens via:
- Shared git remote
- After user accepts changes, sandbox pushes, user pulls (or vice versa)

## Protocol Specification

### Communication

The plugin exposes two communication methods:

1. **WebSocket** (primary) - `ws://localhost:4097/ws`
   - Persistent bidirectional connection
   - Server pushes events in real-time
   - Client sends commands and receives responses
   
2. **HTTP REST** (fallback/testing) - `http://localhost:4097`
   - Simple request/response
   - Good for testing with curl

### Design Decisions

Based on requirements discussion:

1. **Hunk format**: Unified diff format - parsed on neovim side for display
2. **Feedback endpoint**: WebSocket or HTTP - both supported
3. **Real-time status**: Yes - events pushed via WebSocket immediately
4. **Multiple suggestions**: Supported - each has unique ID, can apply feedback independently
5. **Partial apply**: Hunk-level granularity - each hunk applied/rejected independently
6. **AI notification**: Feedback is injected into AI's session via prompt injection

### Event Types (Server → Client via WebSocket)

#### suggestion.ready

Emitted when the AI has prepared changes for review.

```typescript
interface SuggestionReady {
  type: "suggestion.ready"
  suggestion: {
    id: string                    // unique suggestion ID (UUID)
    jj_change_id: string          // jj change ID for this suggestion
    description: string           // human-readable description of changes
    files: string[]               // list of affected file paths
    hunks: Hunk[]                 // the actual changes, broken into hunks
  }
}

interface Hunk {
  id: string                      // unique hunk ID within suggestion (e.g., "suggestion-id:file:hunk-index")
  file: string                    // relative file path
  diff: string                    // unified diff format for this hunk
                                  // includes @@ line numbers, context, and +/- lines
                                  // neovim parses this for display (inline, side-by-side, etc.)
}
```

**Example hunk diff:**
```diff
@@ -10,7 +10,9 @@ function example() {
   const x = 1;
   const y = 2;
-  return x + y;
+  // Add validation
+  if (x < 0 || y < 0) throw new Error("negative");
+  return x + y;
   // trailing context
 }
```

#### suggestion.error

Emitted when something goes wrong in the sandbox.

```typescript
interface SuggestionError {
  type: "suggestion.error"
  code: "experiment_failed" | "sync_failed" | "jj_error" | "apply_failed" | "unknown"
  message: string                 // human-readable error message
  suggestion_id?: string          // if related to a specific suggestion
  hunk_id?: string                // if related to a specific hunk
}
```

#### suggestion.status

Real-time progress updates while AI is working. Sent periodically with one-line status messages.

```typescript
interface SuggestionStatus {
  type: "suggestion.status"
  suggestion_id?: string          // if related to a specific suggestion
  status: "working" | "testing" | "ready" | "applying" | "applied" | "partial"
  message: string                 // one-line status message
                                  // e.g., "Running tests...", "3/5 hunks applied"
}
```

#### suggestion.hunk_applied

Emitted when a single hunk has been successfully applied (after user accepts).

```typescript
interface SuggestionHunkApplied {
  type: "suggestion.hunk_applied"
  suggestion_id: string
  hunk_id: string
  action: "accepted" | "modified" | "rejected"
}
```

### Client Commands (Client → Server via WebSocket)

Commands are sent as JSON messages. Each command can include an optional `id` field for request/response correlation.

#### feedback

```typescript
{
  type: "feedback"
  id?: string                       // optional, for response correlation
  suggestionId: string
  hunkId: string
  action: "accept" | "reject" | "modify"
  modifiedDiff?: string             // required if action is "modify"
  comment?: string
}
```

#### complete

```typescript
{
  type: "complete"
  id?: string
  suggestionId: string
  action: "finalize" | "discard"
}
```

#### list

```typescript
{
  type: "list"
  id?: string
}
```

#### get

```typescript
{
  type: "get"
  id?: string
  suggestionId: string
}
```

### Response Messages (Server → Client)

Responses to commands include the original `id` if provided:

```typescript
{
  type: "response"
  id?: string                       // echoed from request
  success: boolean
  data?: object                     // command-specific data
  error?: string                    // if success is false
}
```

### Feedback Types (Alternative: HTTP REST API)

Feedback can also be sent via HTTP POST for simpler integrations:

#### HunkFeedback

Sent for each hunk as the user reviews. The plugin immediately applies the action.

```typescript
interface HunkFeedback {
  suggestion_id: string           // which suggestion this belongs to
  hunk_id: string                 // which hunk within the suggestion
  action: "accept" | "reject" | "modify"
  modified_diff?: string          // if action is "modify", the user's edited unified diff
  comment?: string                // optional feedback comment for logging
}
```

When feedback is received:
- **accept**: Plugin applies the hunk's diff to the working copy
- **reject**: Plugin skips the hunk, logs rejection
- **modify**: Plugin applies the user's modified diff instead

#### SuggestionComplete

Sent when the user finishes reviewing a suggestion (optional - can also just process hunks individually).

```typescript
interface SuggestionComplete {
  suggestion_id: string
  action: "finalize" | "discard"  // finalize syncs repo, discard abandons remaining
}
```

### Multiple Suggestions

The system supports multiple pending suggestions simultaneously:

```typescript
interface SuggestionList {
  type: "suggestion.list"
  suggestions: Array<{
    id: string
    jj_change_id: string
    description: string
    files: string[]
    hunk_count: number
    reviewed_count: number        // how many hunks have been reviewed
    status: "pending" | "partial" | "complete"
  }>
}
```

User can:
- List all pending suggestions
- Switch between suggestions
- Review hunks from any suggestion
- Each suggestion tracks its own review state

## Workflow

### Happy Path

1. **User requests change**
   - User sends request via opencode chat from their editor
   - Request routed to sandbox opencode instance

2. **AI experiments**
   - AI creates new jj change: `jj new -m "suggestion: <description>"`
   - AI makes edits, runs tests, iterates
   - AI sends periodic `suggestion.status` updates: "Running tests...", "Fixing lint errors..."
   - AI may make multiple attempts before being satisfied

3. **AI publishes suggestion**
   - AI calls `publish_suggestion` tool with description
   - Plugin parses `jj diff` into unified diff hunks
   - Plugin emits `suggestion.ready` event with all hunks

4. **User receives notification**
   - Neovim plugin receives SSE event
   - Shows notification: "Suggestion ready: <description> (5 hunks in 3 files)"
   - User can open review UI or continue working

5. **User reviews hunks**
   - Review UI shows hunks (by file or one at a time)
   - Neovim parses unified diff for display (inline, side-by-side, etc.)
   - For each hunk, user can:
     - **Accept**: Plugin immediately applies the diff
     - **Reject**: Plugin skips, logs rejection
     - **Modify**: User edits in buffer, plugin applies modified diff
   - Each action sends `HunkFeedback` to plugin tool
   - Plugin sends `suggestion.hunk_applied` confirmation

6. **Incremental application**
   - Hunks are applied as user reviews (not batched)
   - User sees changes reflected in their repo immediately
   - Can review remaining hunks at any pace
   - `suggestion.status` updates: "3/5 hunks applied"

7. **User completes review (optional)**
   - User can send `SuggestionComplete` with `finalize` to sync
   - Or just finish reviewing all hunks
   - Plugin syncs with shared repo
   - Remaining suggestions stay pending for later

8. **Feedback logged**
   - All feedback stored in JSONL log
   - Includes: action, comment, timestamp, suggestion context
   - AI can reference for learning patterns

### Error Handling

- **Experiment fails**: AI sends `suggestion.error` with `code: "experiment_failed"`
- **Sync fails**: Plugin sends `suggestion.error` with `code: "sync_failed"`
- **jj error**: Plugin sends `suggestion.error` with `code: "jj_error"`
- User's editor displays error notification with message

## User Interface (Neovim)

### Notification

When `suggestion.ready` received:
- Floating notification or statusline indicator
- Shows description and file count
- Keybind to open review UI (e.g., `<leader>sr`)

### Review UI Options

**Option A: Floating diff window**
- Shows one hunk at a time
- Side-by-side or inline diff view
- Keybinds: `a` accept, `r` reject, `m` modify, `n` next, `p` prev

**Option B: Telescope/picker integration**
- List all hunks in picker
- Preview shows diff
- Actions on selected hunk

**Option C: Inline virtual text**
- Show suggestions inline in the actual file buffer
- Similar to LSP code actions
- Accept/reject per suggestion

### Keybinds (Proposed)

| Key | Action |
|-----|--------|
| `<leader>sr` | Open suggestion review |
| `<leader>sn` | Next hunk |
| `<leader>sp` | Previous hunk |
| `<leader>sa` | Accept current hunk |
| `<leader>sx` | Reject current hunk |
| `<leader>sm` | Modify current hunk (opens in buffer) |
| `<leader>sA` | Accept all remaining |
| `<leader>sX` | Reject all remaining |
| `<leader>sd` | Discard entire suggestion |
| `<leader>sc` | Complete review (apply accepted) |

## Configuration

### Sandbox Side (opencode config)

```json
{
  "suggestion_manager": {
    "port": 4096,
    "feedback_log": "~/.local/share/opencode/feedback.jsonl",
    "auto_sync": true
  }
}
```

### User Side (Neovim)

```lua
require("opencode").setup({
  suggestion_review = {
    server = {
      host = "localhost",
      port = 4097,           -- WebSocket + HTTP server port
    },
    ui = {
      style = "floating",  -- "floating" | "telescope" | "inline"
      position = "right",
      width = 0.4,
    },
    keymaps = {
      open_review = "<leader>sr",
      accept = "a",
      reject = "r",
      modify = "m",
      next_hunk = "n",
      prev_hunk = "p",
      complete = "<CR>",
      discard = "<Esc>",
    },
    notifications = {
      on_ready = true,
      on_error = true,
      on_status = false,
    },
  },
})
```

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check, returns `{healthy: true, service: "suggestion-manager", wsClients: N}` |
| GET | `/suggestions` | List all pending suggestions |
| GET | `/suggestions/:id` | Get suggestion details including hunks |
| POST | `/feedback` | Submit hunk feedback (JSON body: HunkFeedback) |
| POST | `/complete` | Complete suggestion (JSON body: SuggestionComplete) |
| GET | `/ws` | WebSocket upgrade endpoint |

## Design Decisions (Resolved)

1. **Hunk format**: Unified diff format
   - Standard, compact representation
   - Neovim side parses for inline/side-by-side display
   - Includes context lines for accurate patching

2. **Feedback endpoint**: OpenCode plugin tool (`suggestion_feedback`)
   - Plugin receives feedback and immediately applies the action
   - Keeps all logic in the sandbox
   - Leverages existing OpenCode tool infrastructure

3. **Real-time status**: Yes, enabled
   - Periodic one-line status updates via `suggestion.status` events
   - Keeps user informed of progress
   - Final `suggestion.ready` when complete

4. **Multiple suggestions**: Supported
   - Each suggestion has unique ID
   - Can have multiple pending suggestions
   - User can switch between and review independently
   - Each tracks its own review state

5. **Partial apply**: Hunk-level granularity
   - Each hunk applied/rejected independently
   - No "all or nothing" - user controls each piece
   - Plugin handles applying individual hunks to working copy

## OpenCode Plugin Tools

The suggestion-manager plugin exposes the following tools:

### publish_suggestion

Called by AI when changes are ready for review.

```typescript
tool({
  name: "publish_suggestion",
  description: "Publish current jj change as a suggestion for user review",
  args: {
    description: z.string().describe("Human-readable description of the changes"),
    change_id: z.string().optional().describe("jj change ID, defaults to current"),
  },
  async execute(args, ctx) {
    // 1. Get diff from jj: `jj diff -r <change_id>`
    // 2. Parse into hunks (split by file and @@ markers)
    // 3. Generate suggestion ID
    // 4. Store in pending suggestions
    // 5. Emit suggestion.ready event
    // Returns: { suggestion_id, hunk_count, files }
  }
})
```

### suggestion_feedback

Called by neovim plugin when user reviews a hunk.

```typescript
tool({
  name: "suggestion_feedback",
  description: "Submit feedback for a suggestion hunk",
  args: {
    suggestion_id: z.string(),
    hunk_id: z.string(),
    action: z.enum(["accept", "reject", "modify"]),
    modified_diff: z.string().optional(),
    comment: z.string().optional(),
  },
  async execute(args, ctx) {
    // 1. Validate suggestion and hunk exist
    // 2. If accept/modify: apply diff to working copy
    // 3. Log feedback to JSONL
    // 4. Update suggestion state
    // 5. Emit suggestion.hunk_applied event
    // Returns: { success, applied, remaining_hunks }
  }
})
```

### suggestion_status

Called by AI to send progress updates.

```typescript
tool({
  name: "suggestion_status",
  description: "Send a status update to the user",
  args: {
    message: z.string().describe("One-line status message"),
    suggestion_id: z.string().optional(),
  },
  async execute(args, ctx) {
    // Emit suggestion.status event
    // Returns: { sent: true }
  }
})
```

### list_suggestions

Get all pending suggestions.

```typescript
tool({
  name: "list_suggestions",
  description: "List all pending suggestions",
  args: {},
  async execute(args, ctx) {
    // Returns array of pending suggestions with review state
  }
})
```

### complete_suggestion

Finalize or discard a suggestion.

```typescript
tool({
  name: "complete_suggestion",
  description: "Finalize or discard a suggestion",
  args: {
    suggestion_id: z.string(),
    action: z.enum(["finalize", "discard"]),
  },
  async execute(args, ctx) {
    // If finalize: sync with shared repo
    // If discard: abandon jj change, clean up
    // Remove from pending suggestions
  }
})
```

## File Structure

```
# Project repository
/home/claude/source/isolated-ai-coder/
├── DESIGN.md                     # This design document
├── plugin/                       # OpenCode plugin source
│   ├── src/
│   │   ├── index.ts              # Main plugin entry point
│   │   ├── types.ts              # TypeScript type definitions
│   │   ├── diff-parser.ts        # Unified diff parser
│   │   ├── suggestion-store.ts   # Suggestion state management
│   │   ├── event-emitter.ts      # Event emission (WebSocket + SSE)
│   │   ├── patch-applier.ts      # Apply hunks to files
│   │   ├── http-server.ts        # HTTP + WebSocket server
│   │   └── loader.ts             # Plugin loader for symlink setup
│   ├── tests/                    # Test suite
│   │   ├── diff-parser.test.ts
│   │   ├── suggestion-store.test.ts
│   │   ├── event-emitter.test.ts
│   │   └── patch-applier.test.ts
│   ├── package.json
│   └── tsconfig.json
├── test-harness/                 # Test utilities
│   ├── ws-test.ts                # WebSocket test client
│   ├── http-test.ts              # HTTP integration tests
│   ├── live-test.ts              # Live server tests
│   └── direct-test.ts            # Component unit tests
└── nvim/                         # Neovim plugin (TODO)
    └── lua/
        └── suggestion-review/
            ├── init.lua          # Main module
            ├── client.lua        # WebSocket client
            ├── ui.lua            # Review UI components
            ├── feedback.lua      # Send feedback
            └── config.lua        # Configuration handling

# Deployment locations
~/.config/opencode/plugin/
├── suggestion-manager-src/       # Symlink to plugin/src
└── suggestion-manager.ts         # Symlink to loader.ts
```

## Implementation Status

### Completed

1. ~~Finalize protocol decisions~~ (Done - see Design Decisions section)
2. ~~Implement OpenCode plugin (suggestion-manager)~~
   - Unified diff parser with full test coverage
   - Suggestion state management
   - Event emission via app.log() API + WebSocket broadcast
   - Patch applier for applying hunks to files
   - All 6 tools implemented: publish_suggestion, suggestion_feedback, suggestion_status, list_suggestions, complete_suggestion, get_suggestion
   - HTTP server with REST endpoints
   - WebSocket server for real-time bidirectional communication
   - AI notification via session prompt injection
   - Revert-on-reject: rejected hunks are automatically reverted

### Remaining

3. Implement Neovim extension (lua/opencode/suggestion-review/)
4. Test end-to-end workflow
5. Iterate based on usage

## Implementation Notes

### Plugin Architecture

The plugin is structured as follows:

- **types.ts**: All TypeScript interfaces for events, suggestions, hunks, feedback
- **diff-parser.ts**: Parses `jj diff --git` output into structured hunks
- **suggestion-store.ts**: In-memory store for pending suggestions with feedback logging
- **event-emitter.ts**: Emits events via WebSocket broadcast + OpenCode's app.log() API
- **patch-applier.ts**: Applies unified diff hunks to files, supports reversal for undo
- **http-server.ts**: HTTP + WebSocket server for client communication
- **index.ts**: Main plugin that exposes tools to the AI

### Applying Hunks

The patch applier:
- Parses the @@ header to find line positions
- Verifies context lines match (with whitespace normalization)
- Applies additions and removals in-place
- Handles new file creation (when oldStart=0, oldCount=0)
- Supports reversing hunks for undo operations

### jj Integration

```bash
# Create suggestion change
jj new -m "suggestion: <description>"

# Get diff for suggestion
jj diff -r <change_id>

# Get current change ID
jj log -r @ --no-graph -T 'change_id'

# After hunks applied, sync via shared remote
jj git push
```

### Event Broadcasting

Events are broadcast via two channels:

1. **WebSocket** (primary): All connected clients receive events immediately
2. **OpenCode SSE** (fallback): Events also logged via app.log() API for SSE filtering

```typescript
// WebSocket broadcast (primary)
broadcast(event);  // Sends to all connected WebSocket clients

// SSE fallback
await client.app.log({
  body: {
    service: "suggestion-manager",
    level: "info", 
    message: JSON.stringify(event),
    extra: { event: true, eventType: event.type }
  }
})
```

### AI Notification

When feedback is received, the AI is notified via session prompt injection:

```typescript
await client.session.prompt({
  path: { id: sessionId },
  body: {
    noReply: true,
    parts: [{ type: "text", text: "[Suggestion Feedback] User accepted hunk in file.ts..." }]
  }
})
```

This allows the AI to see feedback immediately in the conversation.

### Running Tests

```bash
cd plugin
bun test           # Run all tests
bun test --watch   # Watch mode
bun run typecheck  # Type checking

# Test WebSocket connection
cd test-harness
bun run ws-test.ts # Connect to WebSocket, list suggestions, listen for events

# Test HTTP endpoints
curl http://127.0.0.1:4097/health
curl http://127.0.0.1:4097/suggestions
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SUGGESTION_MANAGER_PORT` | `4097` | HTTP + WebSocket server port |
| `SUGGESTION_MANAGER_HOST` | `127.0.0.1` | Server bind address |
