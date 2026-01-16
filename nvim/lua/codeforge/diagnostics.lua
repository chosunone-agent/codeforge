-- Diagnostics and code actions for CodeForge suggestions

local store = require("codeforge.store")

local M = {}

-- Diagnostic namespace
local ns = vim.api.nvim_create_namespace("codeforge_diagnostics")

-- Track which buffers we've set up code actions for
local registered_buffers = {}

-- Working directory (set by init)
local working_dir = nil

---Set the working directory
---@param dir string
function M.set_working_dir(dir)
  working_dir = dir
end

---Parse the hunk header to get line numbers
---@param diff string
---@return number|nil start_line
---@return number|nil line_count
local function parse_hunk_lines(diff)
  -- Parse @@ -old_start,old_count +new_start,new_count @@
  local new_start, new_count = diff:match("@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
  if new_start then
    new_start = tonumber(new_start)
    new_count = tonumber(new_count) or 1
    return new_start, new_count
  end
  return nil, nil
end

---Get the file path relative to working directory
---@param full_path string
---@return string|nil
local function get_relative_path(full_path)
  if not working_dir then return nil end
  
  -- Normalize paths
  local normalized_full = vim.fn.fnamemodify(full_path, ":p")
  local normalized_wd = vim.fn.fnamemodify(working_dir, ":p")
  
  if normalized_full:sub(1, #normalized_wd) == normalized_wd then
    return normalized_full:sub(#normalized_wd + 1)
  end
  
  return nil
end

---Get hunks for a specific file
---@param file_path string Relative file path
---@return table[] hunks
function M.get_hunks_for_file(file_path)
  local hunks = {}
  local suggestions = store.get_suggestions()
  
  for _, suggestion in ipairs(suggestions) do
    for _, hunk in ipairs(suggestion.hunks) do
      if hunk.file == file_path then
        local hunk_state = store.get_hunk_state(hunk.id)
        if not hunk_state or hunk_state.status == "pending" then
          table.insert(hunks, {
            hunk = hunk,
            suggestion = suggestion,
          })
        end
      end
    end
  end
  
  return hunks
end

---Publish diagnostics for a buffer
---@param bufnr number
function M.publish_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  
  local full_path = vim.api.nvim_buf_get_name(bufnr)
  local rel_path = get_relative_path(full_path)
  
  if not rel_path then
    vim.diagnostic.set(ns, bufnr, {})
    return
  end
  
  local hunks = M.get_hunks_for_file(rel_path)
  local diagnostics = {}
  
  for _, item in ipairs(hunks) do
    local start_line, line_count = parse_hunk_lines(item.hunk.diff)
    if start_line then
      table.insert(diagnostics, {
        lnum = start_line - 1, -- 0-indexed
        end_lnum = start_line - 1 + (line_count or 1) - 1,
        col = 0,
        end_col = 0,
        severity = vim.diagnostic.severity.HINT,
        source = "codeforge",
        message = "AI suggestion available",
        code = item.hunk.id,
        data = {
          hunk_id = item.hunk.id,
          suggestion_id = item.suggestion.id,
          file = item.hunk.file,
        },
      })
    end
  end
  
  vim.diagnostic.set(ns, bufnr, diagnostics)
end

---Clear diagnostics for a buffer
---@param bufnr number
function M.clear_diagnostics(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.diagnostic.set(ns, bufnr, {})
  end
end

---Refresh diagnostics for all buffers
function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      M.publish_diagnostics(bufnr)
    end
  end
end

---Setup code actions for a buffer
---@param bufnr number
local function setup_code_actions(bufnr)
  if registered_buffers[bufnr] then
    return
  end
  registered_buffers[bufnr] = true
  
  -- Clean up when buffer is deleted
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      registered_buffers[bufnr] = nil
    end,
  })
end

---Get code actions for a given context
---@param context table LSP code action context
---@param bufnr number
---@param range table { start = { line, col }, end = { line, col } }
---@return table[] actions
function M.get_code_actions(context, bufnr, range)
  local actions = {}
  
  local full_path = vim.api.nvim_buf_get_name(bufnr)
  local rel_path = get_relative_path(full_path)
  
  if not rel_path then
    return actions
  end
  
  local hunks = M.get_hunks_for_file(rel_path)
  local cursor_line = range.start[1] + 1 -- Convert to 1-indexed
  
  for _, item in ipairs(hunks) do
    local start_line, line_count = parse_hunk_lines(item.hunk.diff)
    if start_line then
      local end_line = start_line + (line_count or 1) - 1
      
      -- Check if cursor is within this hunk's range
      if cursor_line >= start_line and cursor_line <= end_line then
        table.insert(actions, {
          title = "Review AI suggestion (CodeForge)",
          kind = "quickfix",
          data = {
            hunk_id = item.hunk.id,
            suggestion_id = item.suggestion.id,
            file = item.hunk.file,
          },
        })
      end
    end
  end
  
  -- If there are any hunks for this file, offer to review all
  if #hunks > 0 then
    table.insert(actions, {
      title = string.format("Review all AI suggestions for this file (%d)", #hunks),
      kind = "quickfix",
      data = {
        file = rel_path,
        all_hunks = true,
      },
    })
  end
  
  return actions
end

---Execute a code action
---@param action table
function M.execute_action(action)
  local ui = require("codeforge.ui")
  local data = action.data
  
  if data.all_hunks then
    -- Open CodeForge and navigate to this file
    ui.open_for_file(data.file)
  else
    -- Open CodeForge and navigate to specific hunk
    ui.open_for_hunk(data.suggestion_id, data.hunk_id)
  end
end

---Register the code action source
function M.register_code_action_source()
  -- Wrap the original code_action handler to inject our actions
  local original_handler = vim.lsp.handlers["textDocument/codeAction"]
  
  vim.lsp.handlers["textDocument/codeAction"] = function(err, result, ctx, config)
    result = result or {}
    
    -- Get our custom actions
    local bufnr = ctx.bufnr
    local params = ctx.params
    local range = {
      start = { params.range.start.line, params.range.start.character },
      ["end"] = { params.range["end"].line, params.range["end"].character },
    }
    
    local our_actions = M.get_code_actions(ctx, bufnr, range)
    
    -- Add our actions to the result
    for _, action in ipairs(our_actions) do
      table.insert(result, {
        title = action.title,
        kind = action.kind,
        command = {
          title = action.title,
          command = "codeforge.review",
          arguments = { action.data },
        },
      })
    end
    
    -- Call original handler with merged results
    if original_handler then
      original_handler(err, result, ctx, config)
    else
      -- Default behavior if no handler
      vim.lsp.util.apply_text_edits(result, bufnr, "utf-8")
    end
  end
  
  -- Register LSP command executor for our custom command
  local commands = vim.lsp.commands or {}
  commands["codeforge.review"] = function(command, ctx)
    local data = command.arguments[1]
    M.execute_action({ data = data })
  end
  vim.lsp.commands = commands
end

---Show code actions for current cursor position (works without LSP)
function M.show_actions()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local range = {
    start = { cursor[1] - 1, cursor[2] },
    ["end"] = { cursor[1] - 1, cursor[2] },
  }
  
  local actions = M.get_code_actions({}, bufnr, range)
  
  if #actions == 0 then
    vim.notify("[codeforge] No suggestions for this line", vim.log.levels.INFO)
    return
  end
  
  -- Use vim.ui.select to show actions
  local items = {}
  for _, action in ipairs(actions) do
    table.insert(items, action)
  end
  
  vim.ui.select(items, {
    prompt = "CodeForge Actions:",
    format_item = function(item)
      return item.title
    end,
  }, function(choice)
    if choice then
      M.execute_action(choice)
    end
  end)
end

---Setup diagnostics and code actions
function M.setup()
  -- Setup autocmd to publish diagnostics when buffers are opened/changed
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("codeforge_diagnostics", { clear = true }),
    callback = function(ev)
      if vim.bo[ev.buf].buftype == "" then
        M.publish_diagnostics(ev.buf)
        setup_code_actions(ev.buf)
      end
    end,
  })
  
  -- Subscribe to store events to refresh diagnostics
  store.on("on_suggestion_ready", function()
    M.refresh_all()
  end)
  
  store.on("on_hunk_applied", function()
    M.refresh_all()
  end)
  
  -- Register code action source (for LSP integration)
  M.register_code_action_source()
  
  -- Register command for showing actions without LSP
  vim.api.nvim_create_user_command("CodeForgeActions", function()
    M.show_actions()
  end, { desc = "Show CodeForge actions for current line" })
  
  -- Initial refresh
  vim.defer_fn(function()
    M.refresh_all()
  end, 100)
end

return M
