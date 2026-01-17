-- Shadow buffer management for LSP-enabled preview

local store = require("codeforge.store")
local diff_utils = require("codeforge.diff")

local M = {}

-- Current shadow buffer state
local shadow_buf = nil
local shadow_win = nil
local current_file = nil
local current_file_path = nil  -- Full path to the current file
local original_content = nil
local current_hunk = nil -- Track current hunk for modify support
local working_dir = nil -- Working directory for file paths
local hunk_region = nil -- Track the editable region {start_line, end_line}

-- LSP state
local lsp_clients = {}  -- LSP clients attached to shadow buffer
local lsp_version = 0   -- LSP document version counter
local lsp_did_change_autocmd = nil  -- Autocmd ID for tracking changes
local lsp_bootstrap_buf = nil  -- Bootstrap buffer kept alive for LSP
local renamed_original_buf = nil  -- Original buffer that we renamed temporarily

-- Namespace for diff highlights
local ns = vim.api.nvim_create_namespace("codeforge_shadow")

-- Callback for when shadow buffer is saved - receives (modified_diff, hunk)
-- Set by init.lua to wire up to actions.modify_current
-- modified_diff is nil if buffer was not modified (user is accepting as-is)
local on_save_callback = nil

---Set the on-save callback
---@param callback fun(modified_diff: string, hunk: table): boolean
function M.set_on_save_callback(callback)
  on_save_callback = callback
end

---Set the working directory
---@param dir string
function M.set_working_dir(dir)
  working_dir = dir
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

---Handle save command on shadow buffer
---If buffer was modified, computes diff and triggers modify action
---If buffer was NOT modified, triggers accept action (user accepts AI's change as-is)
function M.handle_save()
  if not current_hunk then
    vim.notify("[codeforge] No hunk to save", vim.log.levels.WARN)
    return
  end
  
  if not shadow_buf or not vim.api.nvim_buf_is_valid(shadow_buf) then
    vim.notify("[codeforge] Shadow buffer invalid", vim.log.levels.ERROR)
    return
  end
  
  -- Check if buffer was actually modified
  local is_modified = vim.api.nvim_buf_get_option(shadow_buf, "modified")
  
  if not is_modified then
    -- Buffer not modified = user accepts the AI's change as-is
    -- Pass nil for modified_diff to signal acceptance
    if on_save_callback then
      local success = on_save_callback(nil, current_hunk)
      if success then
        M.close()
      end
    else
      vim.notify("[codeforge] Save callback not configured", vim.log.levels.ERROR)
    end
    return
  end
  
  -- Buffer was modified - compute the modified diff
  local modified_diff, err = M.compute_modified_diff()
  if not modified_diff then
    vim.notify("[codeforge] Failed to compute diff: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  
  -- Call the save callback (which should trigger actions.modify_current)
  if on_save_callback then
    local success = on_save_callback(modified_diff, current_hunk)
    if success then
      -- Close the shadow buffer after successful save
      M.close()
    end
  else
    vim.notify("[codeforge] Save callback not configured", vim.log.levels.ERROR)
  end
end

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

---Check if an LSP client is still valid/active
---@param client table
---@return boolean
local function is_client_active(client)
  if not client then return false end
  -- Check if client is stopped
  if vim.lsp.client_is_stopped and vim.lsp.client_is_stopped(client.id) then
    return false
  end
  -- Also check if client exists in active clients list
  local active = vim.lsp.get_clients({ id = client.id })
  return #active > 0
end

---Send LSP didChange notification for shadow buffer content
---@param file_path string The original file path (for URI)
local function send_lsp_did_change(file_path)
  if not shadow_buf or not vim.api.nvim_buf_is_valid(shadow_buf) then
    return
  end
  
  lsp_version = lsp_version + 1
  local text = table.concat(vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false), "\n")
  local uri = vim.uri_from_fname(file_path)
  
  for _, client in ipairs(lsp_clients) do
    if is_client_active(client) then
      client.notify("textDocument/didChange", {
        textDocument = {
          uri = uri,
          version = lsp_version,
        },
        contentChanges = {
          { text = text },
        },
      })
    end
  end
end

---Send LSP didClose notification and restore original file's LSP state if needed
---@param file_path string The original file path (for URI)
local function send_lsp_did_close(file_path)
  local uri = vim.uri_from_fname(file_path)
  
  -- Send didClose for our virtual document
  for _, client in ipairs(lsp_clients) do
    if is_client_active(client) then
      client.notify("textDocument/didClose", {
        textDocument = { uri = uri },
      })
    end
  end
  
  -- Note: original buffer name restoration is handled in M.close() after shadow buffer is deleted
  -- to avoid "buffer with this name already exists" error
  
  -- Clean up bootstrap buffer if it exists
  -- We kept it alive to prevent premature didClose, now we can delete it
  if lsp_bootstrap_buf and vim.api.nvim_buf_is_valid(lsp_bootstrap_buf) then
    vim.api.nvim_buf_delete(lsp_bootstrap_buf, { force = true })
    lsp_bootstrap_buf = nil
  end
  
  -- Clear LSP state
  lsp_clients = {}
  lsp_version = 0
end

---Find running LSP clients that support a given filetype
---@param filetype string
---@return table[] clients
local function find_clients_for_filetype(filetype)
  local matching = {}
  local all_clients = vim.lsp.get_clients()
  
  for _, client in ipairs(all_clients) do
    -- Check if client config has filetypes
    if client.config and client.config.filetypes then
      for _, ft in ipairs(client.config.filetypes) do
        if ft == filetype then
          table.insert(matching, client)
          break
        end
      end
    end
  end
  
  return matching
end

---Attach existing LSP clients directly to shadow buffer (fast path)
---Used when LSP servers are already running
---@param shadow_buf number
---@param file_path string
---@param shadow_content string[]
---@param filetype string
---@param clients table[] LSP clients to attach
local function attach_existing_clients(shadow_buf, file_path, shadow_content, filetype, clients)
  lsp_clients = {}
  local uri = vim.uri_from_fname(file_path)
  local text = table.concat(shadow_content, "\n")
  
  -- Check if the real file is already open in LSP
  -- If so, we need to close it first before opening with shadow content
  local real_buf = vim.fn.bufnr(file_path)
  local real_file_was_open = real_buf ~= -1 and vim.api.nvim_buf_is_valid(real_buf)
  
  for _, client in ipairs(clients) do
    -- Attach client to shadow buffer
    local ok = pcall(vim.lsp.buf_attach_client, shadow_buf, client.id)
    if ok then
      table.insert(lsp_clients, client)
      
      -- If real file was open in LSP, close it first to avoid duplicate didOpen
      if real_file_was_open then
        client.notify("textDocument/didClose", {
          textDocument = { uri = uri },
        })
      end
      
      -- Send didOpen with shadow content for real file URI
      client.notify("textDocument/didOpen", {
        textDocument = {
          uri = uri,
          languageId = filetype,
          version = lsp_version,
          text = text,
        },
      })
    end
  end
  
  -- Set up didChange notifications
  if lsp_did_change_autocmd then
    pcall(vim.api.nvim_del_autocmd, lsp_did_change_autocmd)
  end
  
  if #lsp_clients > 0 then
    lsp_did_change_autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = shadow_buf,
      callback = function()
        send_lsp_did_change(file_path)
      end,
    })
  end
end

---Bootstrap LSP by firing autocmds on the shadow buffer to trigger LSP startup
---Since the shadow buffer already has the real file path, we can use it directly
---@param shadow_buf number The shadow buffer
---@param file_path string Full path to the file
---@param shadow_content string[] Content for the shadow buffer (not used, buffer already has content)
---@param filetype string The filetype
local function bootstrap_lsp(shadow_buf, file_path, shadow_content, filetype)
  -- The shadow buffer already has:
  -- - The real file path as its name
  -- - The shadow content
  -- - The correct filetype
  -- - buftype = "acwrite" (which some LSP configs might reject)
  
  -- We need to trigger LSP startup by firing autocmds
  -- Note: The buffer is already visible in a window (the shadow window)
  
  -- Fire autocmds to trigger LSP attachment
  vim.api.nvim_exec_autocmds("FileType", { 
    buffer = shadow_buf,
    modeline = false,
  })
  vim.api.nvim_exec_autocmds("BufReadPost", { 
    buffer = shadow_buf,
    modeline = false,
  })
  vim.api.nvim_exec_autocmds("BufEnter", { 
    buffer = shadow_buf,
    modeline = false,
  })
  
  -- Wait for LSP to attach
  local attempts = 0
  local max_attempts = 20  -- 2 seconds max
  
  local function check_lsp_attached()
    attempts = attempts + 1
    
    -- Bail if shadow buffer is no longer valid
    if not vim.api.nvim_buf_is_valid(shadow_buf) then
      return
    end
    
    -- Check if LSP attached to shadow buffer
    local clients = vim.lsp.get_clients({ bufnr = shadow_buf })
    
    if #clients > 0 then
      -- LSP attached! Store the clients
      lsp_clients = {}
      for _, client in ipairs(clients) do
        table.insert(lsp_clients, client)
      end
      
      -- Set up didChange notifications for when user edits shadow buffer
      if lsp_did_change_autocmd then
        pcall(vim.api.nvim_del_autocmd, lsp_did_change_autocmd)
      end
      
      lsp_did_change_autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = shadow_buf,
        callback = function()
          send_lsp_did_change(file_path)
        end,
      })
      
    elseif attempts < max_attempts then
      -- Not attached yet, try again
      vim.defer_fn(check_lsp_attached, 100)
    end
    -- If we time out, just continue without LSP - it's not critical
  end
  
  -- Start checking after a short delay
  vim.defer_fn(check_lsp_attached, 50)
end

---Create a shadow buffer for a file
---@param file_path string Full path to the file
---@param content string[]
---@return number
local function create_shadow_buffer(file_path, content)
  local buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch

  -- Mark this as a codeforge shadow buffer
  vim.api.nvim_buf_set_var(buf, "codeforge_shadow", true)
  vim.api.nvim_buf_set_var(buf, "codeforge_original_file", file_path)

  -- Set buffer options
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")  -- Allows :w but we intercept it
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)

  -- If the real file is open in another buffer, temporarily rename it
  -- This allows our shadow buffer to use the real file path for LSP URI
  local existing_buf = vim.fn.bufnr(file_path)
  if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
    -- Rename the original buffer temporarily
    vim.api.nvim_buf_set_name(existing_buf, file_path .. "#original")
    renamed_original_buf = existing_buf
  end
  
  -- Set buffer name to the REAL file path (not #codeforge)
  -- This is crucial for LSP - it uses buffer name to derive URI
  vim.api.nvim_buf_set_name(buf, file_path)

  -- Set filetype for syntax highlighting and LSP
  local ft = get_filetype(file_path)
  vim.api.nvim_buf_set_option(buf, "filetype", ft)

  -- Set content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

  -- Mark as not modified initially
  vim.api.nvim_buf_set_option(buf, "modified", false)
  
  -- Set up BufWriteCmd to intercept saves
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.handle_save()
    end,
  })

  -- Store the file path for LSP cleanup
  current_file_path = file_path

  -- Set up LSP: first try to use already-running clients (fast path)
  -- If no clients running, bootstrap a new server
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    
    -- Fast path: check if any LSP clients for this filetype are already running
    local existing_clients = find_clients_for_filetype(ft)
    if #existing_clients > 0 then
      -- Attach existing clients directly
      attach_existing_clients(buf, file_path, content, ft, existing_clients)
    else
      -- Slow path: need to start LSP server via bootstrap
      bootstrap_lsp(buf, file_path, content, ft)
    end
  end)

  return buf
end

-- Namespace for hunk boundary extmarks (separate from highlights)
local ns_boundaries = vim.api.nvim_create_namespace("codeforge_boundaries")

-- Extmark IDs for start and end boundaries
local boundary_start_id = nil
local boundary_end_id = nil

---Highlight the diff in the shadow buffer and mark editable region with extmarks
---@param buf number
---@param hunk_diff string
---@param start_line number
---@param end_line number
local function highlight_diff(buf, hunk_diff, start_line, end_line)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_boundaries, 0, -1)

  -- Get buffer line count for bounds checking
  local buf_line_count = vim.api.nvim_buf_line_count(buf)
  
  -- Clamp line numbers to valid range
  if start_line < 1 then start_line = 1 end
  if end_line > buf_line_count then end_line = buf_line_count end
  if start_line > end_line then return end  -- Invalid range, skip highlighting

  -- Parse the diff changes to find which lines are added
  local changes = diff_utils.parse_diff_changes(hunk_diff)
  
  -- Walk through the changes and highlight added lines
  -- The key insight: we need to track our position in the buffer as we walk through the diff
  local buffer_line = start_line - 1  -- 0-indexed
  
  for _, change in ipairs(changes) do
    if buffer_line >= buf_line_count then break end  -- Don't go past buffer end
    
    if change.type == "add" then
      -- Highlight the added line
      vim.api.nvim_buf_add_highlight(buf, ns, "DiffAdd", buffer_line, 0, -1)
      buffer_line = buffer_line + 1
    elseif change.type == "context" then
      -- Context line - don't highlight, but move to next line
      buffer_line = buffer_line + 1
    end
    -- "remove" lines don't exist in the shadow buffer, so they don't consume a buffer line
  end
  
  -- Place extmarks at the boundaries - these will move with the text!
  -- Start boundary - right_gravity = true (default) means it stays in place when inserting before it
  boundary_start_id = vim.api.nvim_buf_set_extmark(buf, ns_boundaries, start_line - 1, 0, {
    sign_text = "┌",
    sign_hl_group = "DiffAdd",
    id = 1,  -- Fixed ID so we can find it later
    right_gravity = true,  -- Don't move when inserting at this position
  })
  
  -- End boundary - place at END of the line (col = -1 means end of line)
  -- right_gravity = false means insertions at this line push the mark down
  boundary_end_id = vim.api.nvim_buf_set_extmark(buf, ns_boundaries, end_line - 1, 0, {
    sign_text = "└",
    sign_hl_group = "DiffAdd",
    id = 2,  -- Fixed ID so we can find it later
    right_gravity = false,  -- Move down when inserting at/after this position
  })
  
  -- Fill in the middle with │ signs
  for i = start_line + 1, end_line - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns_boundaries, i - 1, 0, {
      sign_text = "│",
      sign_hl_group = "DiffAdd",
    })
  end
end

---Get the current hunk boundaries from extmarks (they move with edits!)
---Also detects if user added lines past the end boundary and expands accordingly
---@return number|nil, number|nil -- start_line, end_line (1-indexed)
function M.get_current_boundaries()
  if not shadow_buf or not vim.api.nvim_buf_is_valid(shadow_buf) then
    return nil, nil
  end
  
  -- Get the start extmark position
  local start_mark = vim.api.nvim_buf_get_extmark_by_id(shadow_buf, ns_boundaries, 1, {})
  local end_mark = vim.api.nvim_buf_get_extmark_by_id(shadow_buf, ns_boundaries, 2, {})
  
  if #start_mark == 0 or #end_mark == 0 then
    return nil, nil
  end
  
  -- Extmarks are 0-indexed, convert to 1-indexed
  local start_line = start_mark[1] + 1
  local end_line = end_mark[1] + 1
  
  -- Only expand past the end boundary if:
  -- 1. This is a new file (no trailing context), OR
  -- 2. The hunk originally ended at EOF (no trailing context)
  -- 
  -- If there IS trailing context, the hunk ends mid-file and we should NOT
  -- expand past the original boundary.
  if hunk_region then
    local trailing_ctx = hunk_region.trailing_context
    local has_trailing_context = trailing_ctx and #trailing_ctx > 0
    
    -- Only expand if there's NO trailing context (hunk ends at EOF)
    if not has_trailing_context then
      local buf_lines = vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false)
      if #buf_lines > end_line then
        -- Expand to include all lines added after the boundary
        end_line = #buf_lines
      end
    end
  end
  
  return start_line, end_line
end

---Open a shadow buffer showing a hunk preview
---Shows what the file will look like AFTER applying the hunk
---@param hunk table
---@param working_dir string
---@return number|nil, number|nil -- buffer, window
function M.open(hunk, working_dir)
  local file_path = working_dir .. "/" .. hunk.file
  local file_exists = false
  local local_content = {}
  local preview_content = {}

  -- Read the LOCAL file content (before any changes)
  local_content, file_exists = read_file(file_path)
  
  -- Store original local content for potential revert/modify operations
  original_content = vim.deepcopy(local_content)
  
  local showing_diff_only = false
  
  -- Calculate line offset from previous ACCEPTED/MODIFIED hunks in the same suggestion
  local suggestion = store.get_suggestion_by_hunk_id and store.get_suggestion_by_hunk_id(hunk.id)
  local adjusted_diff = hunk.diff
  local offset = 0
  if suggestion then
    -- Get all hunk states to find accepted/modified hunks
    local hunk_states = store.get_hunk_states and store.get_hunk_states() or {}
    
    for _, prev_hunk in ipairs(suggestion.hunks) do
      if prev_hunk.file == hunk.file then
        if prev_hunk.id == hunk.id then
          break
        end
        
        -- Check if this previous hunk was accepted or modified
        local hunk_state = hunk_states[prev_hunk.id]
        if hunk_state and (hunk_state.status == "accepted" or hunk_state.status == "modified") then
          if hunk_state.status == "modified" and hunk_state.modifiedContent then
            -- For modified hunks, calculate actual size change
            local original_size = #prev_hunk.originalLines
            local modified_size = #hunk_state.modifiedContent
            offset = offset + (modified_size - original_size)
          else
            -- For accepted hunks, use the original diff size
            local header = diff_utils.parse_hunk_header(prev_hunk.diff:match("^[^\n]+"))
            if header then
              offset = offset + (header.new_count - header.old_count)
            end
          end
        end
      end
    end
    
    -- Adjust hunk line numbers if there's an offset
    if offset ~= 0 then
      adjusted_diff = adjust_hunk_line_numbers(hunk.diff, offset)
    end
  end
  
  -- Parse header from adjusted diff (not original)
  local header = diff_utils.parse_hunk_header(adjusted_diff:match("^[^\n]+"))
  
  if not file_exists or #local_content == 0 then
    -- File doesn't exist locally - this is a new file, extract content from diff
    preview_content = extract_new_content_from_diff(adjusted_diff)
    showing_diff_only = true
  else
    -- File exists - apply the hunk to show the preview
    local applied, err = diff_utils.apply_hunk(local_content, adjusted_diff)
    if applied then
      preview_content = applied
    else
      -- If hunk doesn't apply cleanly, fall back to showing just the diff content
      -- This can happen if the file has diverged from the expected state
      vim.notify("CodeForge: Hunk may not apply cleanly: " .. (err or "unknown error"), vim.log.levels.WARN)
      preview_content = extract_new_content_from_diff(adjusted_diff)
      showing_diff_only = true
    end
  end
  
  current_file = hunk.file
  current_hunk = hunk -- Store for modify support

  -- Cache the original (pre-change) content in store
  store.cache_original_content(hunk.file, original_content)

  -- Check if we're switching to a different file
  local switching_files = current_file_path and current_file_path ~= file_path
  
  -- Create or reuse shadow buffer
  if shadow_buf and vim.api.nvim_buf_is_valid(shadow_buf) then
    -- If switching files, we need to update LSP
    if switching_files then
      -- Close LSP for old file
      send_lsp_did_close(current_file_path)
      
      -- Remove old didChange autocmd
      if lsp_did_change_autocmd then
        pcall(vim.api.nvim_del_autocmd, lsp_did_change_autocmd)
        lsp_did_change_autocmd = nil
      end
    end
    
    -- Update existing buffer
    vim.api.nvim_buf_set_option(shadow_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, preview_content)
    vim.api.nvim_buf_set_option(shadow_buf, "modified", false)
    
    -- Update buffer name if file changed
    if switching_files then
      local shadow_name = file_path .. "#codeforge"
      vim.api.nvim_buf_set_name(shadow_buf, shadow_name)
      
      -- Update filetype if needed
      local ft = get_filetype(file_path)
      vim.api.nvim_buf_set_option(shadow_buf, "filetype", ft)
      
      -- Store new file path
      current_file_path = file_path
      
      -- Set up LSP for new file
      local existing_clients = find_clients_for_filetype(ft)
      if #existing_clients > 0 then
        attach_existing_clients(shadow_buf, file_path, preview_content, ft, existing_clients)
      else
        bootstrap_lsp(shadow_buf, file_path, preview_content, ft)
      end
    else
      -- Same file, just send didChange to update LSP
      send_lsp_did_change(file_path)
    end
  else
    shadow_buf = create_shadow_buffer(file_path, preview_content)
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

  -- Jump to the changed region and highlight
  if header then
    local target_line
    local highlight_start
    local highlight_end
    
    if not showing_diff_only then
      -- Showing full file with hunk applied - calculate actual buffer position
      -- The hunk is applied at header.old_start in the original file,
      -- which becomes header.old_start + offset in the buffer after previous hunks
      local actual_buffer_start = header.old_start + offset
      target_line = actual_buffer_start
      highlight_start = actual_buffer_start
      highlight_end = actual_buffer_start + header.new_count - 1
    else
      -- Showing extracted diff content only - start from line 1
      target_line = 1
      highlight_start = 1
      highlight_end = #preview_content
    end
    
    -- Extract trailing context from the original hunk for boundary detection
    local trailing_context = {}
    local orig_changes = diff_utils.parse_diff_changes(hunk.diff)
    local seen_change = false
    for _, change in ipairs(orig_changes) do
      if change.type == "context" then
        if seen_change then
          table.insert(trailing_context, change.content)
        end
      else
        seen_change = true
        trailing_context = {} -- Reset on each new change
      end
    end
    
    -- Store the editable region for reference (including metadata for boundary detection)
    hunk_region = {
      start_line = highlight_start,
      end_line = highlight_end,
      is_new_file = (header.old_count == 0),
      trailing_context = trailing_context,
    }
    
    -- Clamp values to valid range
    local content_lines = #preview_content
    if content_lines == 0 then content_lines = 1 end  -- Empty buffer has 1 line
    
    if highlight_start < 1 then highlight_start = 1 end
    if highlight_end < highlight_start then highlight_end = highlight_start end
    if highlight_end > content_lines then highlight_end = content_lines end
    if target_line < 1 then target_line = 1 end
    if target_line > content_lines then target_line = content_lines end
    
    -- Update hunk_region with clamped values
    hunk_region.start_line = highlight_start
    hunk_region.end_line = highlight_end
    
    vim.api.nvim_win_set_cursor(shadow_win, { target_line, 0 })

    -- Highlight the changed lines and mark editable region in gutter
    highlight_diff(shadow_buf, adjusted_diff, highlight_start, highlight_end)
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
---Computes diff from original file state to user's modified state for the hunk region
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
  -- These are the lines from the ORIGINAL file (before AI's change)
  local hunk_original_lines = current_hunk.originalLines
  if not hunk_original_lines or (type(hunk_original_lines) == "table" and #hunk_original_lines == 0) then
    hunk_original_lines = extract_original_from_diff(current_hunk.diff)
  end
  
  -- Handle case where originalLines is a string (from JSON)
  if type(hunk_original_lines) == "string" then
    hunk_original_lines = vim.split(hunk_original_lines, "\n")
  end

  -- For new files, there are no original lines (old_count = 0)
  -- In this case, the "original" is empty and we diff against that
  local is_new_file = header.old_count == 0
  if #hunk_original_lines == 0 and not is_new_file then
    return nil, "Could not determine original content"
  end

  -- Get the full buffer content (user's modified version)
  local buf_lines = vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false)
  
  -- Get the current hunk boundaries from extmarks - these move with the text!
  local buf_start, buf_end = M.get_current_boundaries()
  
  if not buf_start or not buf_end then
    -- Fallback to original header positions if extmarks not found
    buf_start = header.new_start
    buf_end = header.new_start + header.new_count - 1
  end
  
  -- Clamp to buffer bounds
  if buf_start < 1 then buf_start = 1 end
  if buf_end > #buf_lines then buf_end = #buf_lines end
  
  -- Extract the user's modified lines for this region
  local modified_lines = {}
  for i = buf_start, buf_end do
    table.insert(modified_lines, buf_lines[i] or "")
  end

  -- Compute diff between original hunk lines and user's modified lines
  local modified_diff = diff_utils.compute_diff(
    hunk_original_lines,
    modified_lines,
    3 -- context lines
  )

  if not modified_diff or modified_diff == "" then
    -- No changes from original - user reverted to pre-change state
    return nil, "No changes from original"
  end

  -- Adjust the line numbers in the diff header to match the file position
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
  -- Store file_path before clearing state (needed for buffer restoration)
  local file_path = current_file_path
  
  -- Clean up LSP state first (sends didClose notification)
  if current_file_path then
    send_lsp_did_close(current_file_path)
  end
  
  -- Remove didChange autocmd
  if lsp_did_change_autocmd then
    pcall(vim.api.nvim_del_autocmd, lsp_did_change_autocmd)
    lsp_did_change_autocmd = nil
  end
  
  -- Delete shadow buffer BEFORE restoring original buffer name
  -- (they have the same name, so we can't restore while shadow exists)
  if shadow_buf and vim.api.nvim_buf_is_valid(shadow_buf) then
    -- Clear extmarks before deleting buffer
    vim.api.nvim_buf_clear_namespace(shadow_buf, ns_boundaries, 0, -1)
    vim.api.nvim_buf_delete(shadow_buf, { force = true })
  end
  
  -- NOW restore the original buffer's name (after shadow buffer is deleted)
  if renamed_original_buf and vim.api.nvim_buf_is_valid(renamed_original_buf) and file_path then
    vim.api.nvim_buf_set_name(renamed_original_buf, file_path)
    
    -- Re-open the real file in LSP with its actual content
    local real_content = vim.api.nvim_buf_get_lines(renamed_original_buf, 0, -1, false)
    local real_ft = vim.bo[renamed_original_buf].filetype
    local uri = vim.uri_from_fname(file_path)
    
    for _, client in ipairs(lsp_clients) do
      if is_client_active(client) then
        client.notify("textDocument/didOpen", {
          textDocument = {
            uri = uri,
            languageId = real_ft or "text",
            version = 0,
            text = table.concat(real_content, "\n"),
          },
        })
      end
    end
    
    renamed_original_buf = nil
  end
  
  shadow_buf = nil
  shadow_win = nil
  current_file = nil
  current_file_path = nil
  original_content = nil
  current_hunk = nil
  hunk_region = nil
  boundary_start_id = nil
  boundary_end_id = nil
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

---Get the current editable hunk region
---@return { start_line: number, end_line: number }|nil
function M.get_hunk_region()
  return hunk_region
end

return M
