-- Debug test to understand the highlighting bug in detail
-- Run with: nvim --headless -c "PlenaryBustedFile tests/shadow_highlight_debug_spec.lua"

-- Mock store module for tests
local mock_store = {
  cache_original_content = function() end,
  get_original_content = function() return nil end,
  get_suggestion_by_hunk_id = function(hunk_id)
    return {
      id = "test-suggestion",
      hunks = {
        -- Previous hunks that create offset
        {
          id = "test-suggestion:test.lua:0",
          file = "test.lua",
          diff = "@@ -10,3 +10,5 @@\n line10\n+added1\n+added2\n line11",
        },
        {
          id = "test-suggestion:test.lua:1",
          file = "test.lua",
          diff = "@@ -604,3 +606,5 @@\n line604\n+added3\n+added4\n line605",
        },
        {
          id = "test-suggestion:test.lua:2",
          file = "test.lua",
          diff = "@@ -643,3 +647,5 @@\n line643\n+added5\n+added6\n line644",
        },
        {
          id = "test-suggestion:test.lua:3",
          file = "test.lua",
          diff = "@@ -671,3 +677,5 @@\n line671\n+added7\n+added8\n line672",
        },
        {
          id = "test-suggestion:test.lua:4",
          file = "test.lua",
          diff = "@@ -770,3 +778,5 @@\n line770\n+added9\n+added10\n line771",
        },
        -- The problematic hunk
        {
          id = "test-suggestion:test.lua:5",
          file = "test.lua",
          diff = "@@ -778,3 +788,5 @@\n line778\n+added11\n+added12\n line779",
        },
      },
    }
  end,
}
package.loaded["codeforge.store"] = mock_store

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")

describe("shadow highlighting debug", function()
  local test_file = "/tmp/test_codeforge_debug/test.lua"
  local test_dir = "/tmp/test_codeforge_debug"
  
  before_each(function()
    vim.fn.mkdir(test_dir, "p")
    local file = io.open(test_file, "w")
    for i = 1, 850 do
      file:write(string.format("line%d\n", i))
    end
    file:close()
    shadow.set_working_dir(test_dir)
  end)
  
  after_each(function()
    shadow.close()
    os.remove(test_file)
    vim.fn.delete(test_dir, "rf")
  end)

  it("debug highlight placement for hunk at L778", function()
    local hunk = {
      id = "test-suggestion:test.lua:5",
      file = "test.lua",
      diff = "@@ -778,3 +788,5 @@\n line778\n+added11\n+added12\n line779",
      description = "Add lines at L778",
    }
    
    -- Calculate offset manually to verify
    local suggestion = mock_store.get_suggestion_by_hunk_id(hunk.id)
    local offset = 0
    local found_current = false
    
    for _, prev_hunk in ipairs(suggestion.hunks) do
      if prev_hunk.file == hunk.file then
        if prev_hunk.id == hunk.id then
          found_current = true
          break
        end
        if not found_current then
          local header = diff_utils.parse_hunk_header(prev_hunk.diff:match("^[^\n]+"))
          if header then
            offset = offset + (header.new_count - header.old_count)
          end
        end
      end
    end
    
    print(string.format("Expected offset: %d", offset))
    
    -- Adjust the hunk diff manually
    local adjusted_diff = hunk.diff
    if offset ~= 0 then
      local lines = vim.split(hunk.diff, "\n")
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
            print(string.format("Adjusted header from @@ -%d,%d +%d,%d @@ to @@ -%d%s +%d%s @@",
              old_start, old_count, new_start, new_count,
              old_start, old_count_str, adjusted_new_start, new_count_str))
          end
        end
      end
      adjusted_diff = table.concat(lines, "\n")
    end
    
    print(string.format("Original diff header: %s", hunk.diff:match("^[^\n]+")))
    print(string.format("Adjusted diff header: %s", adjusted_diff:match("^[^\n]+")))
    
    -- Parse the adjusted header
    local adjusted_header = diff_utils.parse_hunk_header(adjusted_diff:match("^[^\n]+"))
    print(string.format("Adjusted header values: new_start=%d, new_count=%d", 
      adjusted_header.new_start, adjusted_header.new_count))
    
    -- Open shadow buffer
    local buf, win = shadow.open(hunk, test_dir)
    
    -- Get buffer content
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    print(string.format("Buffer has %d lines", #content))
    
    -- Check what's around line 778-790
    print("Content around line 778-795:")
    for i = 775, 795 do
      if i <= #content then
        print(string.format("Line %d: %s", i, content[i]))
      end
    end
    
    -- Get cursor position
    local cursor = vim.api.nvim_win_get_cursor(win)
    print(string.format("Cursor at line %d", cursor[1]))
    
    -- Get highlights
    local ns = vim.api.nvim_create_namespace("codeforge_shadow")
    local highlights = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    print(string.format("Found %d highlights", #highlights))
    
    for _, hl in ipairs(highlights) do
      local hl_line = hl[2] + 1
      print(string.format("Highlight at line %d (content: %s)", hl_line, content[hl_line] or "nil"))
    end
    
    -- Also check boundary extmarks
    local ns_boundaries = vim.api.nvim_create_namespace("codeforge_boundaries")
    local boundaries = vim.api.nvim_buf_get_extmarks(buf, ns_boundaries, 0, -1, {})
    print(string.format("Found %d boundary extmarks", #boundaries))
    
    for _, b in ipairs(boundaries) do
      local b_line = b[2] + 1
      print(string.format("Boundary at line %d (content: %s)", b_line, content[b_line] or "nil"))
    end
    
    -- Now let's manually trace what highlight_diff should do
    print("\n--- Manual trace of highlight_diff logic ---")
    local changes = diff_utils.parse_diff_changes(adjusted_diff)
    print(string.format("Parsed %d changes from adjusted diff", #changes))
    
    local start_line = adjusted_header.new_start -- This is what highlight_diff receives
    print(string.format("highlight_diff called with start_line=%d, end_line=%d", 
      start_line, start_line + adjusted_header.new_count - 1))
    
    local buffer_line = start_line - 1 -- 0-indexed
    print(string.format("Starting buffer_line (0-indexed) = %d", buffer_line))
    
    for i, change in ipairs(changes) do
      print(string.format("Change %d: type=%s", i, change.type))
      if change.type == "add" then
        print(string.format("  Would highlight line %d (1-indexed)", buffer_line + 1))
        buffer_line = buffer_line + 1
      elseif change.type == "context" then
        print(string.format("  Would skip line %d (1-indexed)", buffer_line + 1))
        buffer_line = buffer_line + 1
      end
    end
    
    -- The bug is likely that we're highlighting at the wrong position
    -- Let's see where the added lines actually are in the buffer
    print("\n--- Finding added lines in buffer ---")
    for i, line in ipairs(content) do
      if line:match("^added%d+") then
        print(string.format("Found added line '%s' at buffer line %d", line, i))
      end
    end
    
    assert.is_true(cursor[1] >= 788 and cursor[1] <= 795,
      string.format("Cursor should be near line 788 (adjusted position), got line %d", cursor[1]))
  end)
end)
