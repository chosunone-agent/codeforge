-- Actions for accepting, rejecting, and modifying hunks

local store = require("codeforge.store")
local diff_utils = require("codeforge.diff")

local M = {}

-- Working directory (set by init)
local working_dir = nil

---Set the working directory
---@param dir string
function M.set_working_dir(dir)
  working_dir = dir
end

-- Reference to the WebSocket client (set by init.lua)
local ws_client = nil

---Set the WebSocket client reference
---@param client table
function M.set_client(client)
  ws_client = client
end

---Send feedback to the server
---@param suggestion_id string
---@param hunk_id string
---@param action "accept" | "reject" | "modify"
---@param modified_diff? string
---@param comment? string
---@return boolean
function M.send_feedback(suggestion_id, hunk_id, action, modified_diff, comment)
  if not ws_client or not ws_client:is_active() then
    vim.notify("[codeforge] Not connected to server", vim.log.levels.ERROR)
    return false
  end

  -- Get relative working directory
  local cwd = working_dir or vim.fn.getcwd()
  local home = vim.fn.expand("~")
  local relative_cwd = cwd
  if cwd:sub(1, #home) == home then
    relative_cwd = cwd:sub(#home + 2)  -- +2 to skip the trailing slash
  end

  local message = {
    type = "feedback",
    suggestionId = suggestion_id,
    hunkId = hunk_id,
    action = action,
    workingDirectory = relative_cwd,
  }

  if modified_diff then
    message.modifiedDiff = modified_diff
  end

  if comment then
    message.comment = comment
  end

  ws_client:send_json(message)
  return true
end

---Apply a hunk diff to a buffer (or open the file in a buffer first)
---@param file_path string Relative file path
---@param diff string The unified diff to apply
---@return boolean success
---@return string|nil error
local function apply_hunk_locally(file_path, diff)
  if not working_dir then
    return false, "Working directory not set"
  end
  
  local full_path = working_dir .. "/" .. file_path
  
  -- Find or open the buffer for this file
  local bufnr = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local buf_name = vim.api.nvim_buf_get_name(b)
      if buf_name == full_path then
        -- Skip shadow buffers (they have the real file path but are marked)
        local is_shadow = pcall(function()
          return vim.api.nvim_buf_get_var(b, "codeforge_shadow")
        end)
        if not is_shadow then
          bufnr = b
          break
        end
      elseif buf_name == full_path .. "#original" then
        -- Found the original buffer that was renamed by shadow buffer
        bufnr = b
        break
      end
    end
  end
  
  -- If buffer not found, read from file
  local lines = {}
  if bufnr then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    local file = io.open(full_path, "r")
    if file then
      for line in file:lines() do
        table.insert(lines, line)
      end
      file:close()
    end
  end
  
  -- Apply the hunk
  local new_lines, err = diff_utils.apply_hunk(lines, diff)
  if not new_lines then
    return false, err or "Failed to apply hunk"
  end
  
  -- If we have a buffer, update it directly
  if bufnr then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    -- Mark buffer as modified (user decides when to save)
    vim.bo[bufnr].modified = true
  else
    -- No buffer open, open one and set the content
    vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.bo[bufnr].modified = true
  end
  
  return true, nil
end

---Accept the current hunk and apply it locally
---@param comment? string
---@return boolean
function M.accept_current(comment)
  local suggestion = store.get_current_suggestion()
  local hunk = store.get_current_hunk()

  if not suggestion or not hunk then
    vim.notify("[codeforge] No hunk selected", vim.log.levels.WARN)
    return false
  end

  -- Apply the hunk locally first
  local apply_ok, apply_err = apply_hunk_locally(hunk.file, hunk.diff)
  if not apply_ok then
    vim.notify("[codeforge] Failed to apply hunk: " .. (apply_err or "unknown error"), vim.log.levels.ERROR)
    return false
  end

  local success = send_feedback(suggestion.id, hunk.id, "accept", nil, comment)
  if success then
    store.set_hunk_state(hunk.id, "accepted")
    vim.notify(string.format("Accepted hunk in %s", hunk.file), vim.log.levels.INFO)
  end

  return success
end

---Reject the current hunk
---@param comment? string
---@return boolean
function M.reject_current(comment)
  local suggestion = store.get_current_suggestion()
  local hunk = store.get_current_hunk()

  if not suggestion or not hunk then
    vim.notify("[codeforge] No hunk selected", vim.log.levels.WARN)
    return false
  end

  local success = send_feedback(suggestion.id, hunk.id, "reject", nil, comment)
  if success then
    store.set_hunk_state(hunk.id, "rejected")
    vim.notify(string.format("Rejected hunk in %s", hunk.file), vim.log.levels.INFO)
  end

  return success
end

---Modify the current hunk with the shadow buffer's content
---@param modified_diff string -- The computed modified diff
---@param comment? string
---@return boolean
function M.modify_current(modified_diff, comment)
  local suggestion = store.get_current_suggestion()
  local hunk = store.get_current_hunk()

  if not suggestion or not hunk then
    vim.notify("[codeforge] No hunk selected", vim.log.levels.WARN)
    return false
  end

  if not modified_diff or modified_diff == "" then
    vim.notify("[codeforge] No modified diff provided", vim.log.levels.ERROR)
    return false
  end

  -- Apply the modified diff locally
  local apply_ok, apply_err = apply_hunk_locally(hunk.file, modified_diff)
  if not apply_ok then
    vim.notify("[codeforge] Failed to apply modified hunk: " .. (apply_err or "unknown error"), vim.log.levels.ERROR)
    return false
  end

  local success = send_feedback(suggestion.id, hunk.id, "modify", modified_diff, comment)
  if success then
    store.set_hunk_state(hunk.id, "modified")
    vim.notify(string.format("Modified hunk in %s", hunk.file), vim.log.levels.INFO)
  end

  return success
end

---Accept all pending hunks in current suggestion
---@return number -- count of accepted hunks
function M.accept_all()
  local suggestion = store.get_current_suggestion()
  if not suggestion then
    return 0
  end

  local count = 0
  local errors = 0
  for _, hunk in ipairs(suggestion.hunks) do
    local hunk_state = store.get_hunk_state(hunk.id)
    if hunk_state and hunk_state.status == "pending" then
      -- Apply locally first
      local apply_ok, _ = apply_hunk_locally(hunk.file, hunk.diff)
      if apply_ok then
        if send_feedback(suggestion.id, hunk.id, "accept") then
          store.set_hunk_state(hunk.id, "accepted")
          count = count + 1
        end
      else
        errors = errors + 1
      end
    end
  end

  if count > 0 then
    local msg = string.format("Accepted %d hunks", count)
    if errors > 0 then
      msg = msg .. string.format(" (%d failed)", errors)
    end
    vim.notify(msg, vim.log.levels.INFO)
  end

  return count
end

---Reject all pending hunks in current suggestion
---@return number -- count of rejected hunks
function M.reject_all()
  local suggestion = store.get_current_suggestion()
  if not suggestion then
    return 0
  end

  local count = 0
  for _, hunk in ipairs(suggestion.hunks) do
    local hunk_state = store.get_hunk_state(hunk.id)
    if hunk_state and hunk_state.status == "pending" then
      if send_feedback(suggestion.id, hunk.id, "reject") then
        store.set_hunk_state(hunk.id, "rejected")
        count = count + 1
      end
    end
  end

  if count > 0 then
    vim.notify(string.format("Rejected %d hunks", count), vim.log.levels.INFO)
  end

  return count
end

---Complete the current suggestion
---@param action "finalize" | "discard"
---@return boolean
function M.complete_suggestion(action)
  local suggestion = store.get_current_suggestion()
  if not suggestion then
    vim.notify("[codeforge] No suggestion selected", vim.log.levels.WARN)
    return false
  end

  if not ws_client or not ws_client:is_active() then
    vim.notify("[codeforge] Not connected to server", vim.log.levels.ERROR)
    return false
  end

  -- Get relative working directory
  local cwd = working_dir or vim.fn.getcwd()
  local home = vim.fn.expand("~")
  local relative_cwd = cwd
  if cwd:sub(1, #home) == home then
    relative_cwd = cwd:sub(#home + 2)  -- +2 to skip the trailing slash
  end

  ws_client:send_json({
    type = "complete",
    suggestionId = suggestion.id,
    action = action,
    workingDirectory = relative_cwd,
  })

  store.remove_suggestion(suggestion.id)
  vim.notify(string.format("Suggestion %s", action == "finalize" and "finalized" or "discarded"), vim.log.levels.INFO)

  return true
end

---Subscribe to suggestions for a working directory
---@param working_directory string
function M.subscribe(working_directory)
  if not ws_client or not ws_client:is_active() then
    return
  end

  ws_client:send_json({ type = "subscribe", workingDirectory = working_directory })
end

---Request list of suggestions from server
function M.request_list()
  if not ws_client or not ws_client:is_active() then
    return
  end

  -- Get relative working directory
  local cwd = working_dir or vim.fn.getcwd()
  local home = vim.fn.expand("~")
  local relative_cwd = cwd
  if cwd:sub(1, #home) == home then
    relative_cwd = cwd:sub(#home + 2)  -- +2 to skip the trailing slash
  end

  ws_client:send_json({ type = "list", workingDirectory = relative_cwd })
end

---Request details of a specific suggestion
---@param suggestion_id string
function M.request_suggestion(suggestion_id)
  if not ws_client or not ws_client:is_active() then
    return
  end

  -- Get relative working directory
  local cwd = working_dir or vim.fn.getcwd()
  local home = vim.fn.expand("~")
  local relative_cwd = cwd
  if cwd:sub(1, #home) == home then
    relative_cwd = cwd:sub(#home + 2)  -- +2 to skip the trailing slash
  end

  ws_client:send_json({ type = "get", suggestionId = suggestion_id, workingDirectory = relative_cwd })
end

return M
