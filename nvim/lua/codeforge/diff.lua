-- Diff parsing and application utilities

local M = {}

---Parse a unified diff hunk header
---@param header string
---@return { old_start: number, old_count: number, new_start: number, new_count: number }|nil
function M.parse_hunk_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

  if not old_start then
    return nil
  end

  return {
    old_start = tonumber(old_start),
    old_count = tonumber(old_count) or 1,
    new_start = tonumber(new_start),
    new_count = tonumber(new_count) or 1,
  }
end

---Parse a unified diff into changes
---@param diff string
---@return { type: "context"|"add"|"remove", content: string }[]
function M.parse_diff_changes(diff)
  local changes = {}
  local lines = vim.split(diff, "\n")

  for i, line in ipairs(lines) do
    -- Skip the header line
    if not line:match("^@@") then
      if line:sub(1, 1) == " " then
        table.insert(changes, { type = "context", content = line:sub(2) })
      elseif line:sub(1, 1) == "+" then
        table.insert(changes, { type = "add", content = line:sub(2) })
      elseif line:sub(1, 1) == "-" then
        table.insert(changes, { type = "remove", content = line:sub(2) })
      elseif line == "" and i == #lines then
        -- Trailing empty line from split, skip
      elseif line == "" then
        -- Empty context line
        table.insert(changes, { type = "context", content = "" })
      end
    end
  end

  return changes
end

---Apply a hunk to file content
---@param original_lines string[]
---@param diff string
---@return string[]|nil, string|nil -- new_lines, error
function M.apply_hunk(original_lines, diff)
  local lines = vim.split(diff, "\n")
  if #lines == 0 then
    return nil, "Empty diff"
  end

  -- Parse header
  local header = M.parse_hunk_header(lines[1])
  if not header then
    return nil, "Invalid hunk header"
  end

  local changes = M.parse_diff_changes(diff)
  local result = {}

  -- Copy lines before the hunk
  local start_index = header.old_start - 1
  for i = 1, start_index do
    table.insert(result, original_lines[i] or "")
  end

  -- Apply changes
  local original_index = start_index + 1
  for _, change in ipairs(changes) do
    if change.type == "context" then
      table.insert(result, original_lines[original_index] or change.content)
      original_index = original_index + 1
    elseif change.type == "add" then
      table.insert(result, change.content)
    elseif change.type == "remove" then
      original_index = original_index + 1
    end
  end

  -- Copy lines after the hunk
  for i = original_index, #original_lines do
    table.insert(result, original_lines[i])
  end

  return result, nil
end

---Compute unified diff between two sets of lines
---@param old_lines string[]
---@param new_lines string[]
---@param context_lines? number
---@return string
function M.compute_diff(old_lines, new_lines, context_lines)
  context_lines = context_lines or 3

  -- Use vim.diff for the heavy lifting
  local old_text = table.concat(old_lines, "\n")
  local new_text = table.concat(new_lines, "\n")

  local diff = vim.diff(old_text, new_text, {
    algorithm = "histogram",
    ctxlen = context_lines,
    result_type = "unified",
  })

  return diff or ""
end

---Get the "after" state of applying a hunk (for preview)
---@param file_path string
---@param diff string
---@return string[]|nil, string|nil -- new_lines, error
function M.get_hunk_preview(file_path, diff)
  -- Read the original file
  local lines = {}
  local file = io.open(file_path, "r")
  if file then
    for line in file:lines() do
      table.insert(lines, line)
    end
    file:close()
  else
    -- File doesn't exist, might be a new file
    lines = {}
  end

  return M.apply_hunk(lines, diff)
end

---Extract just the added lines from a diff
---@param diff string
---@return string[]
function M.get_added_lines(diff)
  local added = {}
  local changes = M.parse_diff_changes(diff)
  for _, change in ipairs(changes) do
    if change.type == "add" then
      table.insert(added, change.content)
    end
  end
  return added
end

---Extract just the removed lines from a diff
---@param diff string
---@return string[]
function M.get_removed_lines(diff)
  local removed = {}
  local changes = M.parse_diff_changes(diff)
  for _, change in ipairs(changes) do
    if change.type == "remove" then
      table.insert(removed, change.content)
    end
  end
  return removed
end

return M
