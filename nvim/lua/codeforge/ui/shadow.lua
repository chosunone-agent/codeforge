-- Shadow buffer management for LSP-enabled preview

local store = require("codeforge.store")
local diff_utils = require("codeforge.diff")

local M = {}

-- Current shadow buffer state
local shadow_buf = nil
local shadow_win = nil
local current_file = nil
local original_content = nil
local current_hunk = nil -- Track current hunk for modify support

-- Namespace for diff highlights
local ns = vim.api.nvim_create_namespace("codeforge_shadow")

---Read file content
---@param file_path string
---@return string[], boolean -- lines, exists
local function read_file(file_path)
  local lines = {}
  local file = io.open(file_path, "r")
  if file then
    for line in file:lines() do
      table.insert(lines, line)
    end
    file:close()
    return lines, true
  end
  return lines, false
end

---Extract the "new" content from a diff (context + added lines)
---This reconstructs what the file looks like after the change
---@param diff string
---@return string[]
local function extract_new_content_from_diff(diff)
  local lines = {}
  local diff_lines = vim.split(diff, "\n")
  
  for _, line in ipairs(diff_lines) do
    -- Skip header
    if not line:match("^@@") and not line:match("^diff") and not line:match("^index") 
       and not line:match("^%-%-%-") and not line:match("^%+%+%+") then
      if line:sub(1, 1) == " " then
        -- Context line
        table.insert(lines, line:sub(2))
      elseif line:sub(1, 1) == "+" then
        -- Added line
        table.insert(lines, line:sub(2))
      end
      -- Skip "-" lines (removed - not in new content)
    end
  end
  
  return lines
end

---Get the filetype for a file path
---@param file_path string
---@return string
local function get_filetype(file_path)
  local ext = vim.fn.fnamemodify(file_path, ":e")
  local ft_map = {
    ts = "typescript",
    tsx = "typescriptreact",
    js = "javascript",
    jsx = "javascriptreact",
    py = "python",
    rb = "ruby",
    rs = "rust",
    go = "go",
    lua = "lua",
    vim = "vim",
    sh = "sh",
    bash = "bash",
    zsh = "zsh",
    md = "markdown",
    json = "json",
    yaml = "yaml",
    yml = "yaml",
    toml = "toml",
    html = "html",
    css = "css",
    scss = "scss",
    sql = "sql",
    c = "c",
    cpp = "cpp",
    h = "c",
    hpp = "cpp",
  }
  return ft_map[ext] or ext
end

---Create a shadow buffer for a file
---@param file_path string
---@param content string[]
---@return number
local function create_shadow_buffer(file_path, content)
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite") -- Allow "saving" but intercept it
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)

  -- Set the buffer name to the real file path for LSP
  -- This is the key trick - LSP will attach based on this name
  local shadow_name = file_path .. ".codeforge"
  vim.api.nvim_buf_set_name(buf, shadow_name)

  -- Set filetype for syntax highlighting and LSP
  local ft = get_filetype(file_path)
  vim.api.nvim_buf_set_option(buf, "filetype", ft)

  -- Set content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

  -- Mark as not modified initially
  vim.api.nvim_buf_set_option(buf, "modified", false)

  return buf
end

---Highlight the diff in the shadow buffer
---@param buf number
---@param hunk_diff string
---@param start_line number
local function highlight_diff(buf, hunk_diff, start_line)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local changes = diff_utils.parse_diff_changes(hunk_diff)
  local line = start_line - 1 -- 0-indexed

  for _, change in ipairs(changes) do
    if change.type == "add" then
      -- Highlight added lines
      vim.api.nvim_buf_add_highlight(buf, ns, "DiffAdd", line, 0, -1)
      line = line + 1
    elseif change.type == "context" then
      line = line + 1
    end
    -- "remove" lines don't exist in the shadow buffer
  end
end

---Open a shadow buffer showing a hunk (already applied in working copy)
---@param hunk table
---@param working_dir string
---@return number|nil, number|nil -- buffer, window
function M.open(hunk, working_dir)
  local file_path = working_dir .. "/" .. hunk.file
  local file_exists = false
  local current_content = {}

  -- Try to read the current file content (hunk is already applied by jj)
  current_content, file_exists = read_file(file_path)
  
  -- If file doesn't exist locally, extract content from the diff
  local showing_diff_only = false
  if not file_exists or #current_content == 0 then
    current_content = extract_new_content_from_diff(hunk.diff)
    showing_diff_only = true
  end
  
  current_file = hunk.file
  current_hunk = hunk -- Store for modify support

  -- Cache the current content in store
  store.cache_original_content(hunk.file, current_content)
  original_content = current_content

  -- Create or reuse shadow buffer
  if shadow_buf and vim.api.nvim_buf_is_valid(shadow_buf) then
    -- Update existing buffer
    vim.api.nvim_buf_set_option(shadow_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, current_content)
    vim.api.nvim_buf_set_option(shadow_buf, "modified", false)
  else
    shadow_buf = create_shadow_buffer(file_path, current_content)
  end

  -- Open in window if needed
  if not shadow_win or not vim.api.nvim_win_is_valid(shadow_win) then
    -- Find a suitable window (not the list window)
    local list = require("codeforge.ui.list")
    local list_win = list.get_window()

    -- Get list of windows
    local wins = vim.api.nvim_list_wins()
    for _, win in ipairs(wins) do
      if win ~= list_win then
        shadow_win = win
        break
      end
    end

    -- If no other window, create one
    if not shadow_win then
      vim.cmd("vsplit")
      shadow_win = vim.api.nvim_get_current_win()
    end
  end

  -- Set the buffer in the window
  vim.api.nvim_win_set_buf(shadow_win, shadow_buf)

  -- Parse hunk header to find start line (use new_start since change is applied)
  local header = diff_utils.parse_hunk_header(hunk.diff:match("^[^\n]+"))
  if header then
    local target_line
    local highlight_start
    
    if not showing_diff_only then
      -- File exists locally - jump to the actual line in the file
      target_line = header.new_start
      highlight_start = header.new_start
    else
      -- Showing extracted diff content - start from line 1
      target_line = 1
      highlight_start = 1
    end
    
    if target_line > 0 and target_line <= #current_content then
      vim.api.nvim_win_set_cursor(shadow_win, { target_line, 0 })
    end

    -- Highlight the changed lines
    highlight_diff(shadow_buf, hunk.diff, highlight_start)
  end

  return shadow_buf, shadow_win
end

---Get the current content of the shadow buffer
---@return string[]|nil
function M.get_content()
  if shadow_buf and vim.api.nvim_buf_is_valid(shadow_buf) then
    return vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false)
  end
  return nil
end

---Check if the shadow buffer has been modified
---@return boolean
function M.is_modified()
  if shadow_buf and vim.api.nvim_buf_is_valid(shadow_buf) then
    return vim.api.nvim_buf_get_option(shadow_buf, "modified")
  end
  return false
end

---Get the original content before the hunk was applied
---@return string[]|nil
function M.get_original_content()
  return original_content
end

---Get the current hunk
---@return table|nil
function M.get_current_hunk()
  return current_hunk
end

---Extract original lines from a diff (context + removed lines)
---@param diff string
---@return string[]
local function extract_original_from_diff(diff)
  local original = {}
  local lines = vim.split(diff, "\n")
  
  for _, line in ipairs(lines) do
    -- Skip header
    if not line:match("^@@") then
      if line:sub(1, 1) == " " then
        -- Context line
        table.insert(original, line:sub(2))
      elseif line:sub(1, 1) == "-" then
        -- Removed line (part of original)
        table.insert(original, line:sub(2))
      end
      -- Skip "+" lines (added) and other lines
    end
  end
  
  return original
end

---Compute a modified diff for the current hunk
---Uses the hunk's originalLines (pre-change content) and the current buffer content
---@return string|nil, string|nil -- modified_diff, error
function M.compute_modified_diff()
  if not current_hunk then
    return nil, "No current hunk"
  end

  if not shadow_buf or not vim.api.nvim_buf_is_valid(shadow_buf) then
    return nil, "No shadow buffer"
  end

  -- Get the header info from the original diff
  local header = diff_utils.parse_hunk_header(current_hunk.diff:match("^[^\n]+"))
  if not header then
    return nil, "Could not parse hunk header"
  end

  -- Get original lines - from server if available, otherwise extract from diff
  local original_lines = current_hunk.originalLines
  if not original_lines or #original_lines == 0 then
    original_lines = extract_original_from_diff(current_hunk.diff)
  end

  if #original_lines == 0 then
    return nil, "Could not determine original content"
  end

  -- Get the modified content from the shadow buffer for this hunk's region
  local buf_lines = vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false)

  -- Extract the lines that correspond to this hunk's region
  -- The hunk affects lines from new_start to new_start + new_count - 1
  local start_line = header.new_start
  local end_line = header.new_start + header.new_count - 1

  -- Clamp to buffer bounds
  if start_line < 1 then start_line = 1 end
  if end_line > #buf_lines then end_line = #buf_lines end

  local modified_lines = {}
  for i = start_line, end_line do
    table.insert(modified_lines, buf_lines[i] or "")
  end

  -- Compute diff between original lines and modified lines
  local modified_diff = diff_utils.compute_diff(
    original_lines,
    modified_lines,
    3 -- context lines
  )

  if not modified_diff or modified_diff == "" then
    -- No changes from original - this means user reverted to pre-change state
    -- Return a diff that removes the original change
    return diff_utils.compute_diff(current_hunk.originalLines, current_hunk.originalLines, 3), nil
  end

  -- Adjust the line numbers in the diff header to match the file position
  -- The diff from compute_diff starts at line 1, but we need it to start at originalStartLine
  local original_start = current_hunk.originalStartLine or header.old_start
  modified_diff = modified_diff:gsub(
    "^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@",
    function(old_s, old_c, new_s, new_c)
      local old_count = old_c ~= "" and old_c or "1"
      local new_count = new_c ~= "" and new_c or "1"
      return string.format("@@ -%d,%s +%d,%s @@", original_start, old_count, original_start, new_count)
    end
  )

  return modified_diff, nil
end

---Close the shadow buffer
function M.close()
  if shadow_buf and vim.api.nvim_buf_is_valid(shadow_buf) then
    vim.api.nvim_buf_delete(shadow_buf, { force = true })
  end
  shadow_buf = nil
  shadow_win = nil
  current_file = nil
  original_content = nil
  current_hunk = nil
end

---Get the shadow window
---@return number|nil
function M.get_window()
  return shadow_win
end

---Get the shadow buffer
---@return number|nil
function M.get_buffer()
  return shadow_buf
end

---Check if shadow buffer is open
---@return boolean
function M.is_open()
  return shadow_buf ~= nil and vim.api.nvim_buf_is_valid(shadow_buf)
end

return M
