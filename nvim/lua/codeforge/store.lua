-- Store for suggestion state management

local M = {}

---@class Hunk
---@field id string
---@field file string
---@field diff string
---@field originalLines? string[] -- Original content before the change (from server)
---@field originalStartLine? number -- Start line in original file (1-indexed)

---@class Suggestion
---@field id string
---@field jjChangeId string
---@field description string
---@field files string[]
---@field hunks Hunk[]

---@class HunkState
---@field status "pending" | "accepted" | "rejected" | "modified"
---@field modifiedContent? string[] -- If modified, the new content

---@class StoreState
---@field connected boolean
---@field suggestions table<string, Suggestion>
---@field suggestion_order string[] -- Ordered list of suggestion IDs
---@field current_suggestion_id string|nil
---@field current_hunk_index number
---@field hunk_states table<string, HunkState> -- hunk_id -> state
---@field original_content table<string, string[]> -- file_path -> original lines

---@type StoreState
local state = {
  connected = false,
  suggestions = {},
  suggestion_order = {},
  current_suggestion_id = nil,
  current_hunk_index = 1,
  hunk_states = {},
  original_content = {},
}

-- Event callbacks
local listeners = {
  on_connect = {},
  on_disconnect = {},
  on_suggestion_ready = {},
  on_hunk_applied = {},
  on_status = {},
  on_error = {},
}

---Register an event listener
---@param event string
---@param callback function
function M.on(event, callback)
  if listeners[event] then
    table.insert(listeners[event], callback)
  end
end

---Emit an event to all listeners
---@param event string
---@param ... any
local function emit(event, ...)
  if listeners[event] then
    for _, callback in ipairs(listeners[event]) do
      callback(...)
    end
  end
end

---Set connection state
---@param connected boolean
function M.set_connected(connected)
  state.connected = connected
  if connected then
    emit("on_connect")
  else
    emit("on_disconnect")
  end
end

---Check if connected
---@return boolean
function M.is_connected()
  return state.connected
end

---Add or update a suggestion
---@param suggestion Suggestion
function M.add_suggestion(suggestion)
  -- Skip if no hunks (brief from list, wait for full details)
  if not suggestion.hunks or #suggestion.hunks == 0 then
    return
  end

  local is_new = state.suggestions[suggestion.id] == nil

  state.suggestions[suggestion.id] = suggestion

  if is_new then
    table.insert(state.suggestion_order, suggestion.id)
  end

  -- Initialize or update hunk states
  -- Use server-provided states if available, otherwise initialize as pending
  for _, hunk in ipairs(suggestion.hunks) do
    if suggestion.hunkStates and suggestion.hunkStates[hunk.id] then
      -- Server sent state info
      local server_state = suggestion.hunkStates[hunk.id]
      if server_state.reviewed then
        state.hunk_states[hunk.id] = {
          status = server_state.action or "pending",
        }
      else
        state.hunk_states[hunk.id] = { status = "pending" }
      end
    elseif not state.hunk_states[hunk.id] then
      -- No server state and not already tracked
      state.hunk_states[hunk.id] = { status = "pending" }
    end
  end

  -- Set as current if none selected
  if not state.current_suggestion_id then
    state.current_suggestion_id = suggestion.id
    state.current_hunk_index = 1
  end

  if is_new then
    emit("on_suggestion_ready", suggestion)
  end
end

---Remove a suggestion
---@param suggestion_id string
function M.remove_suggestion(suggestion_id)
  state.suggestions[suggestion_id] = nil

  -- Remove from order
  for i, id in ipairs(state.suggestion_order) do
    if id == suggestion_id then
      table.remove(state.suggestion_order, i)
      break
    end
  end

  -- Clear current if it was this one
  if state.current_suggestion_id == suggestion_id then
    state.current_suggestion_id = state.suggestion_order[1]
    state.current_hunk_index = 1
  end
end

---Get all suggestions
---@return Suggestion[]
function M.get_suggestions()
  local result = {}
  for _, id in ipairs(state.suggestion_order) do
    table.insert(result, state.suggestions[id])
  end
  return result
end

---Get a specific suggestion
---@param suggestion_id string
---@return Suggestion|nil
function M.get_suggestion(suggestion_id)
  return state.suggestions[suggestion_id]
end

---Get a suggestion by hunk ID
---@param hunk_id string
---@return Suggestion|nil
function M.get_suggestion_by_hunk_id(hunk_id)
  for _, suggestion in pairs(state.suggestions) do
    for _, hunk in ipairs(suggestion.hunks) do
      if hunk.id == hunk_id then
        return suggestion
      end
    end
  end
  return nil
end

---Get current suggestion
---@return Suggestion|nil
function M.get_current_suggestion()
  if state.current_suggestion_id then
    return state.suggestions[state.current_suggestion_id]
  end
  return nil
end

---Set current suggestion
---@param suggestion_id string
function M.set_current_suggestion(suggestion_id)
  if state.suggestions[suggestion_id] then
    state.current_suggestion_id = suggestion_id
    state.current_hunk_index = 1
  end
end

---Get current hunk
---@return Hunk|nil
function M.get_current_hunk()
  local suggestion = M.get_current_suggestion()
  if suggestion and suggestion.hunks[state.current_hunk_index] then
    return suggestion.hunks[state.current_hunk_index]
  end
  return nil
end

---Get current hunk index
---@return number
function M.get_current_hunk_index()
  return state.current_hunk_index
end

---Set current hunk index
---@param index number
function M.set_current_hunk_index(index)
  local suggestion = M.get_current_suggestion()
  if suggestion and index >= 1 and index <= #suggestion.hunks then
    state.current_hunk_index = index
  end
end

---Move to next hunk
---@return boolean -- true if moved, false if at end
function M.next_hunk()
  local suggestion = M.get_current_suggestion()
  if suggestion and state.current_hunk_index < #suggestion.hunks then
    state.current_hunk_index = state.current_hunk_index + 1
    return true
  end
  return false
end

---Move to previous hunk
---@return boolean -- true if moved, false if at start
function M.prev_hunk()
  if state.current_hunk_index > 1 then
    state.current_hunk_index = state.current_hunk_index - 1
    return true
  end
  return false
end

---Get hunk state
---@param hunk_id string
---@return HunkState|nil
function M.get_hunk_state(hunk_id)
  return state.hunk_states[hunk_id]
end

---Set hunk state and remove from suggestion if reviewed
---@param hunk_id string
---@param status "pending" | "accepted" | "rejected" | "modified"
---@param modified_content? string[]
function M.set_hunk_state(hunk_id, status, modified_content)
  state.hunk_states[hunk_id] = {
    status = status,
    modifiedContent = modified_content,
  }
  
  -- If hunk was reviewed (not pending), remove it from the suggestion
  if status ~= "pending" then
    local found = false
    for _, suggestion in pairs(state.suggestions) do
      if found then break end
      for i, hunk in ipairs(suggestion.hunks) do
        if hunk.id == hunk_id then
          table.remove(suggestion.hunks, i)
          -- Update files list
          local remaining_files = {}
          for _, h in ipairs(suggestion.hunks) do
            remaining_files[h.file] = true
          end
          local new_files = {}
          for _, f in ipairs(suggestion.files) do
            if remaining_files[f] then
              table.insert(new_files, f)
            end
          end
          suggestion.files = new_files
          
          -- Remove suggestion if empty
          if #suggestion.hunks == 0 then
            M.remove_suggestion(suggestion.id)
          end
          found = true
          break
        end
      end
    end
  end
  
  emit("on_hunk_applied", hunk_id, status)
end

---Get count of pending hunks for current suggestion
---@return number
function M.get_pending_count()
  local suggestion = M.get_current_suggestion()
  if not suggestion then
    return 0
  end

  local count = 0
  for _, hunk in ipairs(suggestion.hunks) do
    local hunk_state = state.hunk_states[hunk.id]
    if hunk_state and hunk_state.status == "pending" then
      count = count + 1
    end
  end
  return count
end

---Get total suggestions count
---@return number
function M.get_suggestion_count()
  return #state.suggestion_order
end

---Cache original file content
---@param file_path string
---@param lines string[]
function M.cache_original_content(file_path, lines)
  state.original_content[file_path] = lines
end

---Get cached original content
---@param file_path string
---@return string[]|nil
function M.get_original_content(file_path)
  return state.original_content[file_path]
end

---Clear all state
function M.clear()
  state.suggestions = {}
  state.suggestion_order = {}
  state.current_suggestion_id = nil
  state.current_hunk_index = 1
  state.hunk_states = {}
  state.original_content = {}
end

---Handle status event
---@param status string
---@param message string
---@param suggestion_id? string
function M.handle_status(status, message, suggestion_id)
  emit("on_status", status, message, suggestion_id)
end

---Handle error event
---@param code string
---@param message string
---@param suggestion_id? string
---@param hunk_id? string
function M.handle_error(code, message, suggestion_id, hunk_id)
  emit("on_error", code, message, suggestion_id, hunk_id)
end

return M
