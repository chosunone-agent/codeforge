-- Main UI controller

local store = require("codeforge.store")
local config = require("codeforge.config")
local list = require("codeforge.ui.list")
local shadow = require("codeforge.ui.shadow")
local actions = require("codeforge.actions")

local M = {}

-- Working directory for file paths
local working_dir = nil

---Set the working directory
---@param dir string
function M.set_working_dir(dir)
  working_dir = dir
end

-- Forward declaration for mutual recursion
local on_hunk_selected

---Accept the current hunk (with modification support from shadow buffer)
local function do_accept()
  if shadow.is_modified() then
    -- User made changes, compute and send modified diff
    local modified_diff, err = shadow.compute_modified_diff()
    if err then
      vim.notify("[codeforge] Cannot compute modification: " .. err, vim.log.levels.ERROR)
      return
    end
    if modified_diff then
      actions.modify_current(modified_diff)
    else
      -- No diff means no changes from original - just accept
      actions.accept_current()
    end
  else
    -- No changes, just accept
    actions.accept_current()
  end

  -- Always refresh to show updated state
  list.refresh()
  
  -- Move to next hunk
  if store.next_hunk() then
    on_hunk_selected(store.get_current_hunk_index())
  else
    -- No more hunks
    vim.notify("All hunks reviewed!", vim.log.levels.INFO)
  end
end

---Reject the current hunk
local function do_reject()
  actions.reject_current()

  -- Always refresh to show updated state
  list.refresh()
  
  -- Move to next hunk
  if store.next_hunk() then
    on_hunk_selected(store.get_current_hunk_index())
  else
    vim.notify("All hunks reviewed!", vim.log.levels.INFO)
  end
end

---Accept all remaining hunks
local function do_accept_all()
  actions.accept_all()
  list.refresh()
  M.close()
  vim.notify("All hunks accepted!", vim.log.levels.INFO)
end

---Reject all remaining hunks
local function do_reject_all()
  actions.reject_all()
  list.refresh()
  M.close()
  vim.notify("All hunks rejected!", vim.log.levels.INFO)
end

---Handle hunk selection from the list
---@param hunk_index number
on_hunk_selected = function(hunk_index)
  store.set_current_hunk_index(hunk_index)
  local hunk = store.get_current_hunk()

  if hunk and working_dir then
    shadow.open(hunk, working_dir)
    -- No keymaps on shadow buffer - it's for editing code
  end
end

---Open the review UI
function M.open()
  -- Open the list panel with callbacks (shows "No suggestions" if empty)
  list.open({
    on_select = on_hunk_selected,
    on_accept = do_accept,
    on_reject = do_reject,
    on_accept_all = do_accept_all,
    on_reject_all = do_reject_all,
    on_close = function() M.close() end,
  })

  -- Open the first hunk in shadow buffer if available
  local suggestion = store.get_current_suggestion()
  local hunk = store.get_current_hunk()
  if suggestion and #suggestion.hunks > 0 and hunk and working_dir then
    shadow.open(hunk, working_dir)
  end
end

---Close the review UI
function M.close()
  list.close()
  shadow.close()
end

---Toggle the review UI
function M.toggle()
  if list.is_open() then
    M.close()
  else
    M.open()
  end
end

---Check if UI is open
---@return boolean
function M.is_open()
  return list.is_open()
end

---Refresh the UI after state changes
function M.refresh()
  if list.is_open() then
    list.refresh()
  end
end

---Open CodeForge for a specific file (first hunk in that file)
---@param file_path string Relative file path
function M.open_for_file(file_path)
  -- Find the first hunk for this file
  local suggestions = store.get_suggestions()
  
  for _, suggestion in ipairs(suggestions) do
    for i, hunk in ipairs(suggestion.hunks) do
      if hunk.file == file_path then
        -- Set this suggestion and hunk as current
        store.set_current_suggestion(suggestion.id)
        store.set_current_hunk_index(i)
        
        -- Open the UI
        M.open()
        return
      end
    end
  end
  
  -- No hunk found for this file, just open normally
  M.open()
end

---Open CodeForge for a specific hunk
---@param suggestion_id string
---@param hunk_id string
function M.open_for_hunk(suggestion_id, hunk_id)
  local suggestion = store.get_suggestion(suggestion_id)
  if not suggestion then
    vim.notify("[codeforge] Suggestion not found", vim.log.levels.WARN)
    M.open()
    return
  end
  
  -- Find the hunk index
  for i, hunk in ipairs(suggestion.hunks) do
    if hunk.id == hunk_id then
      store.set_current_suggestion(suggestion_id)
      store.set_current_hunk_index(i)
      M.open()
      return
    end
  end
  
  -- Hunk not found (maybe already reviewed), just open normally
  M.open()
end

-- Subscribe to store events for auto-refresh
store.on("on_suggestion_ready", function(suggestion)
  vim.notify(
    string.format("[codeforge] New suggestion: %s (%d hunks)", suggestion.description, #suggestion.hunks),
    vim.log.levels.INFO
  )
  M.refresh()
end)

store.on("on_hunk_applied", function(hunk_id, status)
  M.refresh()
end)

return M
