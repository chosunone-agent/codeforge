-- Hunk list panel UI

local store = require("codeforge.store")
local config = require("codeforge.config")

local M = {}

-- Buffer and window for the list
local list_buf = nil
local list_win = nil

-- Buffer and window for the pinned header
local header_buf = nil
local header_win = nil

-- UI state
local show_help = false
-- file_path -> true/false if explicitly set, nil means use default (auto-expand current file)
local expanded_files = {}

-- Namespace for highlights
local ns = vim.api.nvim_create_namespace("codeforge_list")

---Get status icon for a hunk
---@param status string
---@return string
local function status_icon(status)
  if status == "pending" then
    return "○"
  elseif status == "accepted" then
    return "✓"
  elseif status == "rejected" then
    return "✗"
  elseif status == "modified" then
    return "~"
  end
  return "?"
end

---Get highlight group for a status
---@param status string
---@return string
local function status_highlight(status)
  if status == "pending" then
    return "Comment"
  elseif status == "accepted" then
    return "DiagnosticOk"
  elseif status == "rejected" then
    return "DiagnosticError"
  elseif status == "modified" then
    return "DiagnosticWarn"
  end
  return "Normal"
end

---Scroll the list window to show the current hunk
---@param hunk_index number
local function scroll_to_hunk(hunk_index)
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    return
  end
  
  if not line_to_hunk then
    return
  end
  
  -- Find the line that corresponds to this hunk index
  local target_line = nil
  for line_idx, idx in pairs(line_to_hunk) do
    if idx == hunk_index then
      target_line = line_idx + 1  -- Convert to 1-indexed
      break
    end
  end
  
  if target_line then
    local ok = pcall(vim.api.nvim_win_set_cursor, list_win, { target_line, 0 })
    if ok then
      vim.api.nvim_win_call(list_win, function()
        vim.cmd("normal! zz")
      end)
    end
  end
end

---Render the pinned header (with optional help)
local function render_header()
  if not header_buf or not vim.api.nvim_buf_is_valid(header_buf) then
    return
  end

  local lines = {}
  local suggestion = store.get_current_suggestion()
  
  if not suggestion or #suggestion.hunks == 0 then
    lines = { 
      "CodeForge",
      string.rep("─", 38),
      "",
      "No pending suggestions",
      "",
    }
  else
    table.insert(lines, "CodeForge")
    table.insert(lines, string.rep("─", 38))
    -- Truncate description if too long
    local desc = suggestion.description
    if #desc > 36 then
      desc = desc:sub(1, 33) .. "..."
    end
    table.insert(lines, desc)
    table.insert(lines, string.format("Pending: %d hunks in %d files", 
      #suggestion.hunks, #suggestion.files))
    
    if show_help then
      table.insert(lines, string.rep("─", 38))
      table.insert(lines, " C-y Accept    C-n Reject")
      table.insert(lines, " C-a Accept all  C-x Reject all")
      table.insert(lines, " Tab/za  Toggle file")
      table.insert(lines, " q  Close      ?  Hide help")
      table.insert(lines, " j/k to navigate")
      table.insert(lines, string.rep("─", 38))
    else
      table.insert(lines, string.rep("─", 38) .. " ? help")
    end
  end

  vim.api.nvim_buf_set_option(header_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(header_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(header_buf, "modifiable", false)
  
  -- Resize header window based on content
  if header_win and vim.api.nvim_win_is_valid(header_win) then
    vim.api.nvim_win_set_height(header_win, #lines)
  end
end

-- Map from display line to hunk index (for navigation)
---@type table<number, number>
local line_to_hunk = {}
-- Map from display line to file path (for toggling)
---@type table<number, string>
local line_to_file = {}

---Render the hunk list grouped by file with collapse/expand
local function render_list()
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then
    return
  end

  local lines = {}
  local highlights = {}
  line_to_hunk = {}
  line_to_file = {}

  local suggestion = store.get_current_suggestion()
  if not suggestion or #suggestion.hunks == 0 then
    vim.api.nvim_buf_set_option(list_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, {
      "",
      "  No pending changes",
      "",
      "  Waiting for suggestions",
      "  from the AI assistant...",
      "",
      "  Press q to close",
    })
    vim.api.nvim_buf_set_option(list_buf, "modifiable", false)
    render_header()
    return
  end

  local current_index = store.get_current_hunk_index()

  -- Group PENDING hunks by file (skip reviewed hunks)
  local files_order = {}
  local hunks_by_file = {}
  for i, hunk in ipairs(suggestion.hunks) do
    local hunk_state = store.get_hunk_state(hunk.id) or { status = "pending" }
    -- Only include pending hunks
    if hunk_state.status == "pending" then
      if not hunks_by_file[hunk.file] then
        hunks_by_file[hunk.file] = {}
        table.insert(files_order, hunk.file)
      end
      table.insert(hunks_by_file[hunk.file], { hunk = hunk, index = i })
    end
  end

  -- Find which file contains the current hunk (auto-expand it)
  local current_hunk = suggestion.hunks[current_index]
  local current_file = current_hunk and current_hunk.file

  -- Render grouped by file (only files with pending hunks)
  for _, file_path in ipairs(files_order) do
    local file_hunks = hunks_by_file[file_path]
    local pending_count = #file_hunks
    
    -- Determine expanded state:
    -- - If explicitly set (true/false), use that
    -- - Otherwise, auto-expand only if it contains the current hunk
    local is_expanded
    if expanded_files[file_path] ~= nil then
      is_expanded = expanded_files[file_path]
    else
      is_expanded = (file_path == current_file)
    end
    
    -- File header line
    local collapse_icon = is_expanded and "▾" or "▸"
    local file_display = file_path
    if #file_display > 28 then
      file_display = "..." .. file_display:sub(-25)
    end
    local count_str = string.format("(%d)", pending_count)
    
    local file_line = string.format("%s %s %s", collapse_icon, file_display, count_str)
    table.insert(lines, file_line)
    
    local file_line_idx = #lines - 1
    line_to_file[file_line_idx] = file_path
    
    -- Highlight file header
    table.insert(highlights, {
      line = file_line_idx,
      is_file_header = true,
      all_done = false,
    })
    
    -- Render hunks if expanded
    if is_expanded then
      for _, h in ipairs(file_hunks) do
        local is_current = h.index == current_index
        local prefix = is_current and "  ▶ " or "    "
        
        -- Show line number if available
        local line_info = ""
        if h.hunk.originalStartLine then
          line_info = string.format("L%d", h.hunk.originalStartLine)
        end
        
        local hunk_line = string.format("%s○ %s", prefix, line_info)
        table.insert(lines, hunk_line)
        
        local hunk_line_idx = #lines - 1
        line_to_hunk[hunk_line_idx] = h.index
        
        table.insert(highlights, {
          line = hunk_line_idx,
          icon_col = #prefix,
          status = "pending",
          is_current = is_current,
        })
      end
    end
  end

  -- Set buffer content
  vim.api.nvim_buf_set_option(list_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(list_buf, "modifiable", false)

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.is_file_header then
      -- Highlight file headers
      local hl_group = hl.all_done and "Comment" or "Directory"
      vim.api.nvim_buf_add_highlight(list_buf, ns, hl_group, hl.line, 0, -1)
    else
      -- Highlight the status icon
      vim.api.nvim_buf_add_highlight(
        list_buf,
        ns,
        status_highlight(hl.status),
        hl.line,
        hl.icon_col,
        hl.icon_col + 3
      )

      -- Highlight current line
      if hl.is_current then
        vim.api.nvim_buf_add_highlight(list_buf, ns, "CursorLine", hl.line, 0, -1)
      end
    end
  end
  
  -- Also update header
  render_header()
end

---Toggle expand state of file at current cursor line
local function toggle_file_at_cursor()
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    return
  end
  
  local cursor = vim.api.nvim_win_get_cursor(list_win)
  local line_idx = cursor[1] - 1  -- 0-indexed
  
  local file_path = line_to_file[line_idx]
  if file_path then
    -- Get current effective state and toggle it
    local current_state = expanded_files[file_path]
    if current_state == nil then
      -- Was using default (auto-expand for current file)
      -- Check if it's currently expanded due to being current file
      local suggestion = store.get_current_suggestion()
      local current_index = store.get_current_hunk_index()
      local current_hunk = suggestion and suggestion.hunks[current_index]
      local is_current_file = current_hunk and current_hunk.file == file_path
      -- Toggle from the effective state
      expanded_files[file_path] = not is_current_file
    else
      expanded_files[file_path] = not current_state
    end
    render_list()
  end
end

---Get hunk index at current cursor line
---@return number|nil
local function get_hunk_at_cursor()
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    return nil
  end
  
  local cursor = vim.api.nvim_win_get_cursor(list_win)
  local line_idx = cursor[1] - 1  -- 0-indexed
  
  return line_to_hunk[line_idx]
end

---Toggle help display in header
local function toggle_help()
  show_help = not show_help
  render_header()
end

---Create a scratch buffer
---@return number
local function create_scratch_buffer()
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "codeforge")

  return buf
end

---@class ListCallbacks
---@field on_select fun(hunk_index: number) -- Callback when hunk is selected
---@field on_accept fun() -- Callback to accept current hunk
---@field on_reject fun() -- Callback to reject current hunk
---@field on_accept_all fun() -- Callback to accept all hunks
---@field on_reject_all fun() -- Callback to reject all hunks
---@field on_close fun() -- Callback to close UI

---Open the list panel with pinned header
---@param callbacks ListCallbacks
---@return number|nil -- window id
function M.open(callbacks)
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.api.nvim_set_current_win(list_win)
    return list_win
  end

  local opts = config.get()
  local width = opts.ui.list_width
  local header_height = 5

  -- Save current window to return to for shadow buffer
  local original_win = vim.api.nvim_get_current_win()

  -- Create the vertical split on the right
  vim.cmd("botright " .. width .. "vsplit")
  local panel_win = vim.api.nvim_get_current_win()

  -- Create list buffer and set it in the panel
  list_buf = create_scratch_buffer()
  vim.api.nvim_win_set_buf(panel_win, list_buf)
  list_win = panel_win

  -- Now split the panel horizontally for the header (above the list)
  vim.cmd("aboveleft " .. header_height .. "split")
  header_win = vim.api.nvim_get_current_win()
  header_buf = create_scratch_buffer()
  vim.api.nvim_win_set_buf(header_win, header_buf)
  
  -- Header window options
  vim.api.nvim_win_set_option(header_win, "number", false)
  vim.api.nvim_win_set_option(header_win, "relativenumber", false)
  vim.api.nvim_win_set_option(header_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(header_win, "winfixheight", true)
  vim.api.nvim_win_set_option(header_win, "winfixwidth", true)
  vim.api.nvim_win_set_option(header_win, "cursorline", false)
  vim.api.nvim_win_set_option(header_win, "wrap", true)
  vim.api.nvim_win_set_option(header_win, "statusline", " ")

  -- Go back to list window and set options
  vim.api.nvim_set_current_win(list_win)
  
  -- List window options
  vim.api.nvim_win_set_option(list_win, "number", false)
  vim.api.nvim_win_set_option(list_win, "relativenumber", false)
  vim.api.nvim_win_set_option(list_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(list_win, "winfixwidth", true)
  vim.api.nvim_win_set_option(list_win, "cursorline", false)
  vim.api.nvim_win_set_option(list_win, "statusline", " ")

  -- Setup keymaps for list buffer
  local keymaps = opts.keymaps

  local function map_list(key, action)
    vim.keymap.set("n", key, action, { buffer = list_buf, nowait = true })
  end
  
  local function map_header(key, action)
    vim.keymap.set("n", key, action, { buffer = header_buf, nowait = true })
  end

  -- Select hunk at cursor or toggle file with Enter
  map_list("<CR>", function()
    local hunk_idx = get_hunk_at_cursor()
    if hunk_idx then
      store.set_current_hunk_index(hunk_idx)
      render_list()
      callbacks.on_select(hunk_idx)
    else
      -- Maybe on a file line, try to toggle
      toggle_file_at_cursor()
    end
  end)
  
  -- Toggle file collapse with Tab or za (vim fold style)
  map_list("<Tab>", toggle_file_at_cursor)
  map_list("za", toggle_file_at_cursor)
  
  -- Accept/reject keymaps
  map_list(keymaps.accept, callbacks.on_accept)
  map_list(keymaps.reject, callbacks.on_reject)
  map_list(keymaps.accept_all, callbacks.on_accept_all)
  map_list(keymaps.reject_all, callbacks.on_reject_all)
  
  -- Also map to header buffer
  map_header(keymaps.accept, callbacks.on_accept)
  map_header(keymaps.reject, callbacks.on_reject)
  map_header(keymaps.accept_all, callbacks.on_accept_all)
  map_header(keymaps.reject_all, callbacks.on_reject_all)
  
  -- Update selection when cursor moves (using CursorMoved autocmd)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = list_buf,
    callback = function()
      local hunk_idx = get_hunk_at_cursor()
      if hunk_idx and hunk_idx ~= store.get_current_hunk_index() then
        store.set_current_hunk_index(hunk_idx)
        render_list()
        callbacks.on_select(hunk_idx)
      end
    end,
  })

  -- Close
  map_list(keymaps.close, callbacks.on_close)
  map_header(keymaps.close, callbacks.on_close)

  -- Help toggle
  map_list("?", toggle_help)
  map_header("?", toggle_help)

  -- Render initial content
  render_list()
  scroll_to_hunk(store.get_current_hunk_index())

  return list_win
end

---Close the list panel
function M.close()
  if header_win and vim.api.nvim_win_is_valid(header_win) then
    vim.api.nvim_win_close(header_win, true)
  end
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.api.nvim_win_close(list_win, true)
  end
  list_win = nil
  list_buf = nil
  header_win = nil
  header_buf = nil
  show_help = false
  expanded_files = {}
end

---Check if list is open
---@return boolean
function M.is_open()
  return list_win ~= nil and vim.api.nvim_win_is_valid(list_win)
end

---Refresh the list display
function M.refresh()
  render_list()
  scroll_to_hunk(store.get_current_hunk_index())
end

---Get the list window
---@return number|nil
function M.get_window()
  return list_win
end

---Get the list buffer
---@return number|nil
function M.get_buffer()
  return list_buf
end

return M
