-- Tests for codeforge.ui.shadow module
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Mock store module for tests
local mock_store = {
  cache_original_content = function() end,
  get_original_content = function() return nil end,
  get_suggestion_by_hunk_id = function(hunk_id)
    -- Mock suggestion with multiple hunks for testing offset calculation
    return {
      id = "test-suggestion",
      hunks = {
        {
          id = "test-suggestion:test.lua:0",
          file = "test.lua",
          diff = "@@ -1,3 +1,5 @@\n line1\n+added1\n+added2\n line2\n line3",
        },
        {
          id = "test-suggestion:test.lua:1",
          file = "test.lua",
          diff = "@@ -5,1 +7,3 @@\n line5\n+added3\n+added4",
        },
      },
    }
  end,
}
package.loaded["codeforge.store"] = mock_store

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")

describe("shadow", function()
  after_each(function()
    -- Clean up any open shadow buffers
    shadow.close()
  end)

  describe("working directory", function()
    it("can set working directory", function()
      -- Should not error
      shadow.set_working_dir("/test/path")
    end)
  end)

  describe("on_save_callback", function()
    it("can set save callback", function()
      local called = false
      shadow.set_on_save_callback(function()
        called = true
        return true
      end)
      
      -- Callback is stored but not called until save
      assert.is_false(called)
    end)
  end)

  describe("buffer state", function()
    it("starts with no buffer open", function()
      assert.is_false(shadow.is_open())
      assert.is_nil(shadow.get_buffer())
      assert.is_nil(shadow.get_window())
    end)

    it("returns nil for content when no buffer", function()
      assert.is_nil(shadow.get_content())
    end)

    it("returns false for modified when no buffer", function()
      assert.is_false(shadow.is_modified())
    end)

    it("returns nil for current hunk when none", function()
      assert.is_nil(shadow.get_current_hunk())
    end)

    it("returns nil for hunk region when none", function()
      assert.is_nil(shadow.get_hunk_region())
    end)
  end)

  describe("close", function()
    it("can close when no buffer open", function()
      -- Should not error
      shadow.close()
      assert.is_false(shadow.is_open())
    end)
  end)
end)

-- Test the helper functions indirectly through the diff module
describe("shadow diff integration", function()
  describe("extract content from diff", function()
    it("diff module parses changes correctly for shadow buffer", function()
      local hunk = "@@ -1,3 +1,4 @@\n line1\n+inserted\n line2\n line3"
      local changes = diff_utils.parse_diff_changes(hunk)
      
      -- Should have 4 entries: context, add, context, context
      assert.equals(4, #changes)
      assert.equals("context", changes[1].type)
      assert.equals("line1", changes[1].content)
      assert.equals("add", changes[2].type)
      assert.equals("inserted", changes[2].content)
    end)

    it("can apply hunk to reconstruct new content", function()
      local original = { "line1", "line2", "line3" }
      local hunk = "@@ -1,3 +1,4 @@\n line1\n+inserted\n line2\n line3"
      
      local result, err = diff_utils.apply_hunk(original, hunk)
      
      assert.is_nil(err)
      assert.equals(4, #result)
      assert.equals("line1", result[1])
      assert.equals("inserted", result[2])
      assert.equals("line2", result[3])
      assert.equals("line3", result[4])
    end)
  end)

  describe("compute_modified_diff", function()
    it("diff module can compute diff between old and new", function()
      local old = { "line1", "line2" }
      local new = { "line1", "modified", "line2" }
      
      local diff = diff_utils.compute_diff(old, new)
      
      assert.is_not_nil(diff)
      assert.truthy(diff:match("%+modified"))
    end)
  end)

  describe("highlighting with offset", function()
    it("applies hunk correctly with line offset", function()
      -- Create a test file with enough lines to match the mock suggestion
      local test_file = "/tmp/test_codeforge_shadow/test.lua"
      vim.fn.mkdir("/tmp/test_codeforge_shadow", "p")
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:write("line4\n")
      file:write("line5\n")
      file:close()

      -- Set working directory
      shadow.set_working_dir("/tmp/test_codeforge_shadow")

      -- Create a hunk that would be at line 7 (after offset adjustment)
      -- This simulates a second hunk in a suggestion where the first hunk added lines
      local hunk = {
        id = "test-suggestion:test.lua:1",
        file = "test.lua",
        diff = "@@ -5,1 +7,3 @@\n line5\n+added3\n+added4",
        description = "Add lines at end",
      }

      -- Open shadow buffer
      local buf, win = shadow.open(hunk, "/tmp/test_codeforge_shadow")

      -- Verify buffer was created
      assert.is_not_nil(buf)
      assert.is_true(vim.api.nvim_buf_is_valid(buf))

      -- Get the buffer content
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- The hunk should have been applied to the file
      -- Original: line1, line2, line3, line4, line5
      -- After applying hunk with offset: line1, line2, line3, line4, line5, added3, added4
      assert.equals(7, #content)
      assert.equals("line1", content[1])
      assert.equals("line2", content[2])
      assert.equals("line3", content[3])
      assert.equals("line4", content[4])
      assert.equals("line5", content[5])
      assert.equals("added3", content[6])
      assert.equals("added4", content[7])

      -- Clean up
      shadow.close()
      os.remove(test_file)
      vim.fn.delete("/tmp/test_codeforge_shadow", "rf")
    end)
  end)
end)
