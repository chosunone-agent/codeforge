-- Test to reproduce the shadow buffer highlighting bug with later hunks
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Mock store module for tests
local mock_store = {
  cache_original_content = function() end,
  get_original_content = function() return nil end,
  get_suggestion_by_hunk_id = function(hunk_id)
    -- Create a suggestion with multiple hunks to simulate the bug scenario
    -- Early hunks work correctly, later hunks have broken highlighting
    return {
      id = "test-suggestion",
      hunks = {
        -- Hunk 1: Early hunk at L10 (works correctly)
        {
          id = "test-suggestion:test.lua:0",
          file = "test.lua",
          diff = "@@ -10,3 +10,5 @@\n line10\n+added1\n+added2\n line11",
        },
        -- Hunk 2: Hunk at L604 (works correctly)
        {
          id = "test-suggestion:test.lua:1",
          file = "test.lua",
          diff = "@@ -604,3 +606,5 @@\n line604\n+added3\n+added4\n line605",
        },
        -- Hunk 3: Hunk at L643 (works correctly)
        {
          id = "test-suggestion:test.lua:2",
          file = "test.lua",
          diff = "@@ -643,3 +647,5 @@\n line643\n+added5\n+added6\n line644",
        },
        -- Hunk 4: Hunk at L671 (works correctly)
        {
          id = "test-suggestion:test.lua:3",
          file = "test.lua",
          diff = "@@ -671,3 +677,5 @@\n line671\n+added7\n+added8\n line672",
        },
        -- Hunk 5: Hunk at L770 (works correctly)
        {
          id = "test-suggestion:test.lua:4",
          file = "test.lua",
          diff = "@@ -770,3 +778,5 @@\n line770\n+added9\n+added10\n line771",
        },
        -- Hunk 6: Hunk at L778 (BROKEN - highlighting jumps to end)
        {
          id = "test-suggestion:test.lua:5",
          file = "test.lua",
          diff = "@@ -778,3 +788,5 @@\n line778\n+added11\n+added12\n line779",
        },
        -- Hunk 7: Hunk at L818 (BROKEN - highlighting jumps to end)
        {
          id = "test-suggestion:test.lua:6",
          file = "test.lua",
          diff = "@@ -818,3 +830,5 @@\n line818\n+added13\n+added14\n line819",
        },
      },
    }
  end,
}
package.loaded["codeforge.store"] = mock_store

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")

describe("shadow highlighting bug reproduction", function()
  local test_file = "/tmp/test_codeforge_highlight/test.lua"
  local test_dir = "/tmp/test_codeforge_highlight"
  
  before_each(function()
    -- Create test directory
    vim.fn.mkdir(test_dir, "p")
    
    -- Create a file with 850 lines to match our test scenario
    local file = io.open(test_file, "w")
    for i = 1, 850 do
      file.write(file, string.format("line%d\n", i))
    end
    file:close()
    
    -- Set working directory
    shadow.set_working_dir(test_dir)
  end)
  
  after_each(function()
    -- Clean up
    shadow.close()
    os.remove(test_file)
    vim.fn.delete(test_dir, "rf")
  end)

  it("should apply correct highlighting for early hunks (L10)", function()
    -- Open hunk at line 10 (should work correctly)
    local hunk = {
      id = "test-suggestion:test.lua:0",
      file = "test.lua",
      diff = "@@ -10,3 +10,5 @@\n line10\n+added1\n+added2\n line11",
      description = "Add lines at L10",
    }
    
    local buf, win = shadow.open(hunk, test_dir)
    
    -- Verify buffer was created
    assert.is_not_nil(buf)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    
    -- Get highlight positions for added lines
    local highlights = vim.api.nvim_buf_get_extmarks(buf, 
      vim.api.nvim_create_namespace("codeforge_shadow"), 
      0, -1, {})
    
    -- Should have highlights at the correct positions (around line 10-12)
    -- The added lines "added1" and "added2" should be highlighted
    assert.is_true(#highlights > 0, "Should have highlights for early hunk")
    
    -- Get cursor position - should be near line 10
    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.is_true(cursor[1] >= 10 and cursor[1] <= 15, 
      string.format("Cursor should be near line 10, got line %d", cursor[1]))
    
    shadow.close()
  end)

  it("should apply correct highlighting for middle hunks (L604, L643, L671, L770)", function()
    -- Test hunk at line 604
    local hunk = {
      id = "test-suggestion:test.lua:1",
      file = "test.lua",
      diff = "@@ -604,3 +606,5 @@\n line604\n+added3\n+added4\n line605",
      description = "Add lines at L604",
    }
    
    local buf, win = shadow.open(hunk, test_dir)
    
    assert.is_not_nil(buf)
    local cursor = vim.api.nvim_win_get_cursor(win)
    assert.is_true(cursor[1] >= 604 and cursor[1] <= 615,
      string.format("Cursor should be near line 604, got line %d", cursor[1]))
    
    shadow.close()
    
    -- Test hunk at line 643
    hunk = {
      id = "test-suggestion:test.lua:2",
      file = "test.lua",
      diff = "@@ -643,3 +647,5 @@\n line643\n+added5\n+added6\n line644",
      description = "Add lines at L643",
    }
    
    buf, win = shadow.open(hunk, test_dir)
    cursor = vim.api.nvim_win_get_cursor(win)
    assert.is_true(cursor[1] >= 643 and cursor[1] <= 655,
      string.format("Cursor should be near line 643, got line %d", cursor[1]))
    
    shadow.close()
  end)

  it("should apply correct highlighting for later hunks with large offsets (L778, L818)", function()
    -- This test should FAIL with the current implementation, demonstrating the bug
    -- Hunk at line 778 - this should have a large offset from previous hunks
    local hunk = {
      id = "test-suggestion:test.lua:5",
      file = "test.lua",
      diff = "@@ -778,3 +788,5 @@\n line778\n+added11\n+added12\n line779",
      description = "Add lines at L778",
    }
    
    local buf, win = shadow.open(hunk, test_dir)
    
    assert.is_not_nil(buf)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    
    -- Get the buffer content to see what line we're actually at
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    
    -- Get cursor position
    local cursor = vim.api.nvim_win_get_cursor(win)
    
    -- Get highlights
    local ns = vim.api.nvim_create_namespace("codeforge_shadow")
    local highlights = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    
    print(string.format("Buffer has %d lines", #content))
    print(string.format("Cursor at line %d", cursor[1]))
    print(string.format("Found %d highlights", #highlights))
    
    if #highlights > 0 then
      for _, hl in ipairs(highlights) do
        print(string.format("Highlight at line %d", hl[2] + 1)) -- hl[2] is 0-indexed line
      end
    end
    
    -- The bug: highlighting jumps to end of file instead of correct position
    -- With current implementation, this will likely fail
    assert.is_true(cursor[1] >= 778 and cursor[1] <= 795,
      string.format("Cursor should be near line 778, got line %d", cursor[1]))
    
    -- Verify highlights are at the correct position (around the added lines)
    -- The highlights should be near line 788-790 (where the added lines are after offset)
    local highlight_found_near_correct_position = false
    for _, hl in ipairs(highlights) do
      local hl_line = hl[2] + 1 -- Convert to 1-indexed
      if hl_line >= 788 and hl_line <= 795 then
        highlight_found_near_correct_position = true
        break
      end
    end
    
    assert.is_true(highlight_found_near_correct_position,
      "Highlights should be near the correct position (lines 788-795), not at the end of the file")
    
    shadow.close()
    
    -- Test hunk at line 818 - also should have large offset
    hunk = {
      id = "test-suggestion:test.lua:6",
      file = "test.lua",
      diff = "@@ -818,3 +830,5 @@\n line818\n+added13\n+added14\n line819",
      description = "Add lines at L818",
    }
    
    buf, win = shadow.open(hunk, test_dir)
    cursor = vim.api.nvim_win_get_cursor(win)
    
    print(string.format("Second test - Cursor at line %d", cursor[1]))
    
    -- This should also fail with current implementation
    assert.is_true(cursor[1] >= 818 and cursor[1] <= 835,
      string.format("Cursor should be near line 818, got line %d", cursor[1]))
    
    shadow.close()
  end)

  it("should calculate correct offset for later hunks", function()
    -- Test the offset calculation directly
    local suggestion = mock_store.get_suggestion_by_hunk_id("test-suggestion:test.lua:5")
    
    local offset = 0
    local found_current = false
    
    for _, prev_hunk in ipairs(suggestion.hunks) do
      if prev_hunk.file == "test.lua" then
        if prev_hunk.id == "test-suggestion:test.lua:5" then
          found_current = true
          break
        end
        
        if not found_current then
          local header = diff_utils.parse_hunk_header(prev_hunk.diff:match("^[^\n]+"))
          if header then
            offset = offset + (header.new_count - header.old_count)
            print(string.format("Hunk %s: old_count=%d, new_count=%d, offset=%d", 
              prev_hunk.id, header.old_count, header.new_count, offset))
          end
        end
      end
    end
    
    -- For hunk at L778, we should have accumulated offset from 5 previous hunks
    -- Each hunk adds 2 lines (new_count=5, old_count=3, so +2 per hunk)
    -- Expected offset: 5 * 2 = 10
    assert.equals(10, offset, "Offset should be 10 for hunk at L778")
    
    -- Now test hunk at L818 (6 previous hunks)
    offset = 0
    found_current = false
    
    for _, prev_hunk in ipairs(suggestion.hunks) do
      if prev_hunk.file == "test.lua" then
        if prev_hunk.id == "test-suggestion:test.lua:6" then
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
    
    -- Expected offset: 6 * 2 = 12
    assert.equals(12, offset, "Offset should be 12 for hunk at L818")
  end)
end)
