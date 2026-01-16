---@class CodeForgeConfig
---@field server { host: string, port: number }
---@field ui { list_width: number, position: string }
---@field keymaps table<string, string>
---@field auto_connect boolean

local M = {}

---@type CodeForgeConfig
M.defaults = {
  server = {
    host = "127.0.0.1",
    port = 4097,
  },
  ui = {
    list_width = 40,
    position = "right", -- "left" or "right" for hunk list panel
  },
  keymaps = {
    open = "<leader>cf",        -- Open CodeForge
    actions = "<leader>cfa",    -- Show CodeForge actions for current line
    close = "q",                -- Close UI
    accept = "<C-y>",           -- Accept current hunk (yes)
    reject = "<C-n>",           -- Reject current hunk (no)
    accept_all = "<C-a>",       -- Accept all remaining hunks
    reject_all = "<C-x>",       -- Reject all remaining hunks
  },
  auto_connect = true,          -- Connect to server on setup
}

---@type CodeForgeConfig
M.options = {}

---@param opts? CodeForgeConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

---@return CodeForgeConfig
function M.get()
  return M.options
end

return M
