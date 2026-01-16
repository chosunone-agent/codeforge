-- Minimal init for running tests
-- Sets up the runtime path to include the plugin

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Add plugin to runtime path
vim.opt.rtp:prepend(plugin_root)

-- Add plenary to runtime path (assumes it's installed)
local plenary_path = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.rtp:prepend(plenary_path)
end

-- Disable swap files for tests
vim.opt.swapfile = false

-- Load plenary
vim.cmd([[runtime plugin/plenary.vim]])
