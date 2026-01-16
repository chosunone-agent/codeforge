-- Diagnostics and code actions for CodeForge suggestions

local store = require("codeforge.store")
local diff_utils = require("codeforge.diff")
local actions = require("codeforge.actions")

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

---Check if a hunk is redundant (file content already matches the hunk's result)
---@param file_path string Relative file path
---@param hunk table Hunk object
---@return boolean redundant
local function is_hunk_redundant(file_path, hunk)
  if not working_dir then
    return false
  end
  
  local full_path = working_dir .. "/" .. file_path
  
  -- Read current file content
  local lines = {}
  local file = io.open(full_path, "r")
  if file then
    for line in file:lines() do
      table.insert(lines, line)
    end
    file:close()
  else
    -- File doesn't exist, hunk is not redundant
    return false
  end
  
  -- Apply the hunk to see what the result would be
  local new_lines, err = diff_utils.apply_hunk(lines, hunk.diff)
  if not new_lines then
    -- Failed to apply, can't determine if redundant
    return false
  end
  
  -- Check if the result is exactly the same as the original
  local exact_match = true
  if #new_lines ~= #lines then
    exact_match = false
  else
    for i = 1, #lines do
      if lines[i] ~= new_lines[i] then
        exact_match = false
        break
      end
    end
  end
  
  if exact_match then
    return true
  end
  
  -- Check if the hunk only adds lines that already exist in the file
  -- This catches cases where a hunk adds duplicate lines
  local changes = diff_utils.parse_diff_changes(hunk.diff)
  local only_adds_existing_lines = true
  local has_additions = false
  
  for _, change in ipairs(changes) do
    if change.type == "add" then
      has_additions = true
      -- Check if this line already exists in the file
      local line_exists = false
      for _, line in ipairs(lines) do
        if line == change.content then
          line_exists = true
          break
        end
      end
      if not line_exists then
        only_adds_existing_lines = false
        break
      end
    elseif change.type == "remove" then
      -- If there are any removals, it's not just adding duplicates
      only_adds_existing_lines = false
      break
    end
  end
  
  -- If the hunk only adds lines that already exist, it's redundant
  if has_additions and only_adds_existing_lines then
    return true
  end
  
  return false
end

---Send feedback for a redundant hunk
---@param suggestion_id string
---@param hunk_id string
local function send_redundant_feedback(suggestion_id, hunk_id)
  -- Use a special action to indicate the hunk is redundant
  -- We'll treat it as "accept" since the content is already correct
  actions.send_feedback(suggestion_id, hunk_id, "accept", nil, "Hunk is redundant - file content already matches")
end

---Test helper: Check if a hunk is redundant (exposed for testing)
---@param file_path string Relative file path
---@param hunk table Hunk object
---@return boolean redundant
function M._test_is_hunk_redundant(file_path, hunk)
  return is_hunk_redundant(file_path, hunk)
end

---Test helper: Get the diagnostic namespace (exposed for testing)
---@return number namespace
function M._test_get_namespace()
  return ns
end

---Test helper: Calculate line offset (exposed for testing)
---@param file_path string Relative file path
---@param suggestion table Suggestion object
---@param current_hunk_id string The hunk we're calculating offset for
---@return number offset
function M._test_calculate_line_offset(file_path, suggestion, current_hunk_id)
  return calculate_line_offset(file_path, suggestion, current_hunk_id)
end

---Test helper: Adjust hunk line numbers (exposed for testing)
---@param diff string Hunk diff
---@param offset number Line offset
---@return string Adjusted diff
function M._test_adjust_hunk_line_numbers(diff, offset)
  return adjust_hunk_line_numbers(diff, offset)
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

---Calculate line offset for a file based on all previous hunks in the suggestion
---@param file_path string Relative file path
---@param suggestion table Suggestion object
---@param current_hunk_id string The hunk we're calculating offset for
---@return number offset
local function calculate_line_offset(file_path, suggestion, current_hunk_id)
  local offset = 0
  local found_current = false
  
  for _, hunk in ipairs(suggestion.hunks) do
    if hunk.file == file_path then
      if hunk.id == current_hunk_id then
        found_current = true
        break
      end
      
      -- Only count hunks that come before the current hunk
      if not found_current then
        -- Parse the hunk to get line counts
        local header = diff_utils.parse_hunk_header(hunk.diff)
        if header then
          offset = offset + (header.new_count - header.old_count)
        end
      end
    end
  end
  
  return offset
end

---Adjust hunk line numbers based on offset
---@param diff string Hunk diff
---@param offset number Line offset
---@return string Adjusted diff
local function adjust_hunk_line_numbers(diff, offset)
  if offset == 0 then
    return diff
  end
  
  local lines = vim.split(diff, "\n")
  for i, line in ipairs(lines) do
    if line:match("^@@") then
      local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if old_start then
        old_start = tonumber(old_start)
        old_count = tonumber(old_count) or 1
        new_start = tonumber(new_start)
        new_count = tonumber(new_count) or 1
        
        local adjusted_new_start = new_start + offset
        local old_count_str = old_count > 1 and "," .. old_count or ""
        local new_count_str = new_count > 1 and "," .. new_count or ""
        
        lines[i] = string.format("@@ -%d%s +%d%s @@", old_start, old_count_str, adjusted_new_start, new_count_str)
      end
    end
  end
  
  return table.concat(lines, "\n")
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
    -- Calculate line offset for this hunk (based on all previous hunks in the suggestion)
    local offset = calculate_line_offset(rel_path, item.suggestion, item.hunk.id)
    
    -- Adjust hunk diff if there's an offset
    local adjusted_diff = item.hunk.diff
    if offset ~= 0 then
      adjusted_diff = adjust_hunk_line_numbers(item.hunk.diff, offset)
    end
    
    -- Check if hunk is redundant
    local redundant = is_hunk_redundant(rel_path, {
      id = item.hunk.id,
      file = item.hunk.file,
      diff = adjusted_diff,
    })
    
    if redundant then
      -- Automatically send feedback for redundant hunks
      send_redundant_feedback(item.suggestion.id, item.hunk.id)
      -- Mark as reviewed so it doesn't show up again
      store.set_hunk_state(item.hunk.id, "accepted")
    else
      local start_line, line_count = parse_hunk_lines(adjusted_diff)
      if start_line then
        table.insert(diagnostics, {
          lnum = start_line - 1, -- 0-indexed
          end_lnum = start_line - 1 + (line_count or 1) - 1,
          col = 0,
          end_col = 0,
          severity = vim.diagnostic.severity.HINT,
          source = "codeforge",
          message = item.hunk.description or "AI suggestion available",
          code = item.hunk.id,
          data = {
            hunk_id = item.hunk.id,
            suggestion_id = item.suggestion.id,
            file = item.hunk.file,
          },
        })
      end
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
