-- codeforge.nvim
-- Review AI code suggestions with LSP support

local config = require("codeforge.config")
local store = require("codeforge.store")
local websocket = require("codeforge.websocket")
local actions = require("codeforge.actions")
local ui = require("codeforge.ui")

local M = {}

-- WebSocket client instance
local ws_client = nil

-- Reconnection state
local reconnect_timer = nil
local reconnect_attempts = 0
local max_reconnect_attempts = 10
local reconnect_delay = 2000 -- ms

---Handle a suggestion brief (from list) - fetch full details
---@param brief table Brief suggestion info (id, description, hunkCount, etc.)
local function handle_suggestion_brief(brief)
  -- Only request full details if we don't already have hunks
  local existing = store.get_suggestion(brief.id)
  if existing and existing.hunks and #existing.hunks > 0 then
    return
  end

  -- Request full details
  actions.request_suggestion(brief.id)
end

---Handle incoming WebSocket messages
---@param data string
local function on_message(data)
  local ok, message = pcall(vim.json.decode, data)
  if not ok then
    vim.notify("[codeforge] Failed to parse message: " .. data, vim.log.levels.WARN)
    return
  end

  local msg_type = message.type

  if msg_type == "connected" then
    -- Initial connection, contains brief suggestion list
    -- Request full details for each suggestion
    if message.suggestions then
      for _, brief in ipairs(message.suggestions) do
        handle_suggestion_brief(brief)
      end
    end

  elseif msg_type == "suggestion.ready" then
    -- New suggestion available (should have full details)
    if message.suggestion then
      store.add_suggestion(message.suggestion)
    end

  elseif msg_type == "suggestion.hunk_applied" then
    -- Hunk was applied/rejected/modified
    local status_map = {
      accepted = "accepted",
      rejected = "rejected",
      modified = "modified",
    }
    local status = status_map[message.action] or "pending"
    store.set_hunk_state(message.hunkId, status)

  elseif msg_type == "suggestion.status" then
    store.handle_status(message.status, message.message, message.suggestionId)

  elseif msg_type == "suggestion.error" then
    store.handle_error(message.code, message.message, message.suggestionId, message.hunkId)
    vim.notify(
      string.format("[codeforge] Error: %s - %s", message.code or "unknown", message.message or ""),
      vim.log.levels.ERROR
    )

  elseif msg_type == "response" then
    -- Response to a command we sent
    if message.success then
      -- Handle successful responses
      if message.suggestions then
        -- Response to list command - these are brief, request full details
        for _, brief in ipairs(message.suggestions) do
          handle_suggestion_brief(brief)
        end
      elseif message.suggestion then
        -- Response to get command - this has full details
        store.add_suggestion(message.suggestion)
      end
    else
      vim.notify(
        "[codeforge] Command failed: " .. (message.error or "unknown error"),
        vim.log.levels.WARN
      )
    end
  end
end

---Handle WebSocket connection
local function on_connect()
  store.set_connected(true)
  reconnect_attempts = 0

  -- Subscribe to suggestions for this working directory (relative to home)
  local cwd = vim.fn.getcwd()
  local home = vim.fn.expand("~")
  local relative_cwd = cwd
  if cwd:sub(1, #home) == home then
    relative_cwd = cwd:sub(#home + 2)  -- +2 to skip the trailing slash
  end
  actions.subscribe(relative_cwd)
end

---Handle WebSocket disconnection
local function on_disconnect()
  store.set_connected(false)

  -- Attempt reconnection silently
  if reconnect_attempts < max_reconnect_attempts then
    reconnect_attempts = reconnect_attempts + 1
    reconnect_timer = vim.defer_fn(function()
      M.connect()
    end, reconnect_delay)
  end
end

---Handle WebSocket errors
---@param err string
local function on_error(err)
  -- Only show errors if they're not connection failures during auto-connect
  if reconnect_attempts == 0 then
    vim.notify("[codeforge] Error: " .. err, vim.log.levels.ERROR)
  end
end

---Connect to the suggestion server
function M.connect()
  local opts = config.get()

  -- Cancel any pending reconnect
  if reconnect_timer then
    reconnect_timer = nil
  end

  -- Create new client
  ws_client = websocket.create({
    host = opts.server.host,
    port = opts.server.port,
    path = "/ws",
  })

  if not ws_client then
    return
  end

  -- Set client reference for actions
  actions.set_client(ws_client)

  -- Connect
  ws_client:connect({
    on_connect = on_connect,
    on_message = on_message,
    on_disconnect = on_disconnect,
    on_error = on_error,
  })
end

---Disconnect from the server
function M.disconnect()
  if ws_client then
    ws_client:disconnect()
    ws_client = nil
  end
  store.set_connected(false)
end

---Check if connected
---@return boolean
function M.is_connected()
  return store.is_connected()
end

---Setup the plugin
---@param opts? CodeForgeConfig
function M.setup(opts)
  config.setup(opts)

  -- Set working directory
  local cwd = vim.fn.getcwd()
  ui.set_working_dir(cwd)
  actions.set_working_dir(cwd)
  
  -- Setup diagnostics and code actions
  local diagnostics = require("codeforge.diagnostics")
  diagnostics.set_working_dir(cwd)
  diagnostics.setup()

  -- Setup user commands
  vim.api.nvim_create_user_command("CodeForge", function()
    ui.toggle()
  end, { desc = "Toggle CodeForge UI" })

  vim.api.nvim_create_user_command("CodeForgeConnect", function()
    M.connect()
  end, { desc = "Connect to CodeForge server" })

  vim.api.nvim_create_user_command("CodeForgeDisconnect", function()
    M.disconnect()
  end, { desc = "Disconnect from CodeForge server" })

  vim.api.nvim_create_user_command("CodeForgeAccept", function()
    actions.accept_current()
    ui.refresh()
  end, { desc = "Accept current hunk" })

  vim.api.nvim_create_user_command("CodeForgeReject", function()
    actions.reject_current()
    ui.refresh()
  end, { desc = "Reject current hunk" })

  vim.api.nvim_create_user_command("CodeForgeAcceptAll", function()
    actions.accept_all()
    ui.refresh()
  end, { desc = "Accept all pending hunks" })

  vim.api.nvim_create_user_command("CodeForgeRejectAll", function()
    actions.reject_all()
    ui.refresh()
  end, { desc = "Reject all pending hunks" })

  -- Setup global keymaps
  local keymap_opts = config.get().keymaps
  vim.keymap.set("n", keymap_opts.open, function()
    ui.toggle()
  end, { desc = "Toggle CodeForge" })
  
  vim.keymap.set("n", keymap_opts.actions, function()
    require("codeforge.diagnostics").show_actions()
  end, { desc = "Show CodeForge actions for current line" })

  -- Auto-connect if configured
  if config.get().auto_connect then
    -- Defer to allow nvim to fully start
    vim.defer_fn(function()
      M.connect()
    end, 100)
  end
end

-- Export submodules
M.store = store
M.ui = ui
M.actions = actions
M.config = config

-- Health check (for :checkhealth codeforge)
M.health = require("codeforge.health")

return M
