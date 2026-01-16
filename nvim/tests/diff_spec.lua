-- Tests for codeforge.diff module
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local diff = require("codeforge.diff")

describe("diff", function()
  describe("parse_hunk_header", function()
    it("parses standard hunk header", function()
      local result = diff.parse_hunk_header("@@ -1,3 +1,4 @@")
      assert.is_not_nil(result)
      assert.equals(1, result.old_start)
      assert.equals(3, result.old_count)
      assert.equals(1, result.new_start)
      assert.equals(4, result.new_count)
    end)

    it("parses header with single line counts", function()
      local result = diff.parse_hunk_header("@@ -5 +5,2 @@")
      assert.is_not_nil(result)
      assert.equals(5, result.old_start)
      assert.equals(1, result.old_count) -- defaults to 1
      assert.equals(5, result.new_start)
      assert.equals(2, result.new_count)
    end)

    it("parses header with context text", function()
      local result = diff.parse_hunk_header("@@ -10,5 +12,7 @@ function foo()")
      assert.is_not_nil(result)
      assert.equals(10, result.old_start)
      assert.equals(5, result.old_count)
      assert.equals(12, result.new_start)
      assert.equals(7, result.new_count)
    end)

    it("returns nil for invalid header", function()
      assert.is_nil(diff.parse_hunk_header("not a header"))
      assert.is_nil(diff.parse_hunk_header(""))
      assert.is_nil(diff.parse_hunk_header("--- a/file.txt"))
    end)
  end)

  describe("parse_diff_changes", function()
    it("parses added lines", function()
      local hunk = "@@ -1,2 +1,3 @@\n context\n+added\n context2"
      local changes = diff.parse_diff_changes(hunk)
      
      assert.equals(3, #changes)
      assert.equals("context", changes[1].type)
      assert.equals("context", changes[1].content)
      assert.equals("add", changes[2].type)
      assert.equals("added", changes[2].content)
      assert.equals("context", changes[3].type)
      assert.equals("context2", changes[3].content)
    end)

    it("parses removed lines", function()
      local hunk = "@@ -1,3 +1,2 @@\n context\n-removed\n context2"
      local changes = diff.parse_diff_changes(hunk)
      
      assert.equals(3, #changes)
      assert.equals("context", changes[1].type)
      assert.equals("remove", changes[2].type)
      assert.equals("removed", changes[2].content)
      assert.equals("context", changes[3].type)
    end)

    it("parses mixed changes", function()
      local hunk = "@@ -1,3 +1,3 @@\n context\n-old\n+new\n context2"
      local changes = diff.parse_diff_changes(hunk)
      
      assert.equals(4, #changes)
      assert.equals("context", changes[1].type)
      assert.equals("remove", changes[2].type)
      assert.equals("old", changes[2].content)
      assert.equals("add", changes[3].type)
      assert.equals("new", changes[3].content)
      assert.equals("context", changes[4].type)
    end)

    it("handles empty context lines", function()
      local hunk = "@@ -1,3 +1,3 @@\n \n+added\n "
      local changes = diff.parse_diff_changes(hunk)
      
      assert.equals(3, #changes)
      assert.equals("context", changes[1].type)
      assert.equals("", changes[1].content)
      assert.equals("add", changes[2].type)
      assert.equals("context", changes[3].type)
      assert.equals("", changes[3].content)
    end)
  end)

  describe("apply_hunk", function()
    it("applies addition at start of file", function()
      local original = { "line1", "line2", "line3" }
      local hunk = "@@ -1,2 +1,3 @@\n+new_line\n line1\n line2"
      
      local result, err = diff.apply_hunk(original, hunk)
      
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals(4, #result)
      assert.equals("new_line", result[1])
      assert.equals("line1", result[2])
      assert.equals("line2", result[3])
      assert.equals("line3", result[4])
    end)

    it("applies addition in middle of file", function()
      local original = { "line1", "line2", "line3", "line4" }
      local hunk = "@@ -2,2 +2,3 @@\n line2\n+inserted\n line3"
      
      local result, err = diff.apply_hunk(original, hunk)
      
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals(5, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
      assert.equals("inserted", result[3])
      assert.equals("line3", result[4])
      assert.equals("line4", result[5])
    end)

    it("applies deletion", function()
      local original = { "line1", "line2", "line3", "line4" }
      local hunk = "@@ -2,3 +2,2 @@\n line2\n-line3\n line4"
      
      local result, err = diff.apply_hunk(original, hunk)
      
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals(3, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
      assert.equals("line4", result[3])
    end)

    it("applies replacement", function()
      local original = { "line1", "old_line", "line3" }
      local hunk = "@@ -1,3 +1,3 @@\n line1\n-old_line\n+new_line\n line3"
      
      local result, err = diff.apply_hunk(original, hunk)
      
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals(3, #result)
      assert.equals("line1", result[1])
      assert.equals("new_line", result[2])
      assert.equals("line3", result[3])
    end)

    it("applies to empty file (new file)", function()
      local original = {}
      local hunk = "@@ -0,0 +1,2 @@\n+line1\n+line2"
      
      local result, err = diff.apply_hunk(original, hunk)
      
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.equals(2, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
    end)

    it("returns error for empty diff", function()
      local original = { "line1" }
      local result, err = diff.apply_hunk(original, "")
      
      assert.is_nil(result)
      -- Empty diff has no valid header, so returns "Invalid hunk header"
      assert.equals("Invalid hunk header", err)
    end)

    it("returns error for invalid header", function()
      local original = { "line1" }
      local result, err = diff.apply_hunk(original, "not a valid diff")
      
      assert.is_nil(result)
      assert.equals("Invalid hunk header", err)
    end)
  end)

  describe("compute_diff", function()
    it("computes diff for addition", function()
      local old = { "line1", "line2" }
      local new = { "line1", "inserted", "line2" }
      
      local result = diff.compute_diff(old, new)
      
      assert.is_not_nil(result)
      assert.truthy(result:match("%+inserted"))
    end)

    it("computes diff for deletion", function()
      local old = { "line1", "to_remove", "line2" }
      local new = { "line1", "line2" }
      
      local result = diff.compute_diff(old, new)
      
      assert.is_not_nil(result)
      assert.truthy(result:match("%-to_remove"))
    end)

    it("computes diff for replacement", function()
      local old = { "line1", "old", "line2" }
      local new = { "line1", "new", "line2" }
      
      local result = diff.compute_diff(old, new)
      
      assert.is_not_nil(result)
      assert.truthy(result:match("%-old"))
      assert.truthy(result:match("%+new"))
    end)

    it("returns empty string for identical content", function()
      local lines = { "line1", "line2" }
      
      local result = diff.compute_diff(lines, lines)
      
      assert.equals("", result)
    end)
  end)

  describe("get_added_lines", function()
    it("extracts only added lines", function()
      local hunk = "@@ -1,2 +1,4 @@\n context\n+added1\n-removed\n+added2\n context"
      
      local added = diff.get_added_lines(hunk)
      
      assert.equals(2, #added)
      assert.equals("added1", added[1])
      assert.equals("added2", added[2])
    end)

    it("returns empty for no additions", function()
      local hunk = "@@ -1,2 +1,1 @@\n context\n-removed"
      
      local added = diff.get_added_lines(hunk)
      
      assert.equals(0, #added)
    end)
  end)

  describe("get_removed_lines", function()
    it("extracts only removed lines", function()
      local hunk = "@@ -1,4 +1,2 @@\n context\n-removed1\n+added\n-removed2\n context"
      
      local removed = diff.get_removed_lines(hunk)
      
      assert.equals(2, #removed)
      assert.equals("removed1", removed[1])
      assert.equals("removed2", removed[2])
    end)

    it("returns empty for no removals", function()
      local hunk = "@@ -1,1 +1,2 @@\n context\n+added"
      
      local removed = diff.get_removed_lines(hunk)
      
      assert.equals(0, #removed)
    end)
  end)
end)
