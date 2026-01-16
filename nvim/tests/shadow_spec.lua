-- Tests for codeforge.ui.shadow module
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Mock store module for tests
package.loaded["codeforge.store"] = {
  cache_original_content = function() end,
  get_original_content = function() return nil end,
}

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
end)
