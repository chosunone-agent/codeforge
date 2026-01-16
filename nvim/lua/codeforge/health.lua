-- Health check for codeforge plugin

local M = {}

function M.check()
  local health = vim.health
  
  health.start("codeforge")

  -- Check if plugin is loaded
  local plugin_ok, _ = pcall(require, "codeforge")
  if not plugin_ok then
    health.error("Plugin not loaded")
    return
  end
  health.ok("Plugin loaded")

  -- Check config
  local config_ok, config = pcall(require, "codeforge.config")
  if config_ok then
    local opts = config.get()
    if opts and opts.server then
      health.info(string.format("Server: %s:%d", opts.server.host, opts.server.port))
      health.info(string.format("Auto-connect: %s", tostring(opts.auto_connect)))
    else
      health.warn("Config not initialized - call setup() first")
    end
  else
    health.error("Failed to load config module")
  end

  -- Check store
  local store_ok, store = pcall(require, "codeforge.store")
  if store_ok then
    local connected = store.is_connected()
    if connected then
      health.ok("Connected to server")
    else
      health.warn("Not connected to server")
    end

    local suggestions = store.get_suggestions()
    local count = 0
    for _ in pairs(suggestions) do
      count = count + 1
    end
    health.info(string.format("Suggestions loaded: %d", count))

    local current = store.get_current_suggestion()
    if current then
      health.info(string.format("Current suggestion: %s (%d hunks)", current.description, #current.hunks))
      health.info(string.format("Pending hunks: %d", store.get_pending_count()))
    end
  else
    health.error("Failed to load store module")
  end

  -- Check WebSocket module
  local ws_ok, ws_err = pcall(require, "codeforge.websocket")
  if ws_ok then
    health.ok("WebSocket module loaded")
  else
    health.error("Failed to load WebSocket module: " .. tostring(ws_err))
  end

  -- Check if vim.uv or vim.loop is available
  local uv = vim.uv or vim.loop
  if uv then
    health.ok("libuv available (vim." .. (vim.uv and "uv" or "loop") .. ")")
  else
    health.error("libuv not available - WebSocket won't work")
  end

  -- Check server connectivity
  health.start("Server connectivity")
  
  local opts = config.get()
  if not opts or not opts.server then
    health.warn("Config not initialized")
    return
  end

  local host = opts.server.host
  local port = opts.server.port

  -- Try HTTP health endpoint
  local http_ok = false
  local curl_handle = io.popen(string.format("curl -s -o /dev/null -w '%%{http_code}' --connect-timeout 2 http://%s:%d/health 2>/dev/null", host, port))
  if curl_handle then
    local status = curl_handle:read("*a")
    curl_handle:close()
    if status == "200" then
      http_ok = true
      health.ok(string.format("HTTP server responding at %s:%d", host, port))
    end
  end

  if not http_ok then
    health.error(string.format("Cannot connect to server at %s:%d", host, port))
    health.info("Make sure OpenCode is running with the suggestion-manager plugin")
  end

  -- Check working directory
  health.start("Project")
  local cwd = vim.fn.getcwd()
  local home = vim.fn.expand("~")
  local relative_cwd = cwd
  if cwd:sub(1, #home) == home then
    relative_cwd = cwd:sub(#home + 2)
  end
  health.info(string.format("Working directory: %s", cwd))
  health.info(string.format("Project identifier: %s", relative_cwd))
  
  -- Check diagnostics
  health.start("Diagnostics")
  local diag_ok, diagnostics = pcall(require, "codeforge.diagnostics")
  if diag_ok then
    health.ok("Diagnostics module loaded")
    health.info("Hint diagnostics enabled for files with pending suggestions")
    health.info("Code actions available via LSP")
  else
    health.warn("Diagnostics module not loaded: " .. tostring(diagnostics))
  end
end

return M
