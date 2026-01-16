#!/bin/bash
# Run CodeForge Neovim plugin tests
# Requires plenary.nvim to be installed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Run tests using plenary
nvim --headless -c "PlenaryBustedDirectory $SCRIPT_DIR {minimal_init = '$SCRIPT_DIR/minimal_init.lua'}"
