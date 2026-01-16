# CodeForge

A Neovim plugin for reviewing AI code suggestions with hunk-by-hunk review, LSP integration, and real-time collaboration.

## Overview

CodeForge enables an AI coding assistant (running in a sandboxed environment) to experiment freely with code changes, then present those changes for interactive, hunk-by-hunk review in your editor before applying them to the shared codebase.

## Features

- **Hunk-by-hunk review**: Review code changes one hunk at a time
- **Real-time updates**: WebSocket connection for instant notifications
- **LSP integration**: Show suggestions as diagnostics with code actions
- **Shadow buffer editing**: Edit suggestions in a temporary buffer before accepting
- **Multi-database support**: Works with multiple project databases
- **Working directory normalization**: Handles path resolution across systems
- **Auto-creation**: Automatically creates databases when needed
- **Enhanced error handling**: Robust error reporting and recovery

## Installation

### Neovim Plugin

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "yourusername/codeforge",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("codeforge").setup({
      -- Configuration options
    })
  end
}
```

### OpenCode Plugin

Install the suggestion-manager plugin in your OpenCode configuration:

```bash
cd ~/.config/opencode/plugin
git clone https://github.com/yourusername/codeforge.git
cd codeforge/plugin
bun install
```

## Configuration

```lua
require("codeforge").setup({
  server = {
    host = "127.0.0.1",
    port = 4097,
  },
  auto_connect = true,
  keymaps = {
    open = "<leader>cf",
    actions = "<leader>ca",
  },
})
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `server.host` | string | `"127.0.0.1"` | WebSocket server host |
| `server.port` | number | `4097` | WebSocket server port |
| `auto_connect` | boolean | `true` | Auto-connect on startup |
| `keymaps.open` | string | `"<leader>cf>"` | Toggle CodeForge UI |
| `keymaps.actions` | string | `"<leader>ca>"` | Show actions for current line |

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:CodeForge` | Toggle CodeForge UI |
| `:CodeForgeConnect` | Connect to server |
| `:CodeForgeDisconnect` | Disconnect from server |
| `:CodeForgeAccept` | Accept current hunk |
| `:CodeForgeReject` | Reject current hunk |
| `:CodeForgeAcceptAll` | Accept all pending hunks |
| `:CodeForgeRejectAll` | Reject all pending hunks |

### Keymaps

- `<leader>cf` - Toggle CodeForge UI
- `<leader>ca` - Show CodeForge actions for current line

### LSP Integration

CodeForge integrates with Neovim's LSP to show suggestions as diagnostics. Use `<leader>ca` to see available actions for the current line.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            USER'S NEOVIM                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  codeforge.nvim                                                      │    │
│  │  - Connects via WebSocket for real-time communication               │    │
│  │  - Receives suggestion events                                       │    │
│  │  - Shows LSP diagnostics and code actions                           │    │
│  │  - Provides hunk-by-hunk review UI                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ WebSocket (localhost:4097)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SANDBOX (opencode user)                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  suggestion-manager plugin                                          │    │
│  │  - HTTP + WebSocket server on :4097                                │    │
│  │  - Provides tools for AI (publish_suggestion, etc.)                 │    │
│  │  - Broadcasts events to connected clients                          │    │
│  │  - Receives and processes feedback                                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  Version Control (jj):                                                      │
│  - Each suggestion = its own jj change node                                 │
│  - `jj diff` provides the hunks for review                                  │
│  - Accepted changes synced to shared repo                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Development

### Neovim Plugin

```bash
cd nvim
# Run tests
./tests/run_tests.sh

# Check health
:checkhealth codeforge
```

### OpenCode Plugin

```bash
cd plugin
bun test              # Run tests
bun test --watch      # Watch mode
bun run typecheck     # Type checking
```

## Protocol

### WebSocket Events

#### suggestion.ready
Emitted when AI has prepared changes for review.

```typescript
{
  type: "suggestion.ready",
  suggestion: {
    id: string,
    jj_change_id: string,
    description: string,
    files: string[],
    hunks: Hunk[]
  }
}
```

#### suggestion.hunk_applied
Emitted when a hunk has been applied/rejected/modified.

```typescript
{
  type: "suggestion.hunk_applied",
  suggestion_id: string,
  hunk_id: string,
  action: "accepted" | "modified" | "rejected"
}
```

### Client Commands

#### feedback
Submit feedback for a hunk.

```typescript
{
  type: "feedback",
  suggestionId: string,
  hunkId: string,
  action: "accept" | "reject" | "modify",
  modifiedDiff?: string,
  comment?: string
}
```

## License

AGPL-3.0

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
