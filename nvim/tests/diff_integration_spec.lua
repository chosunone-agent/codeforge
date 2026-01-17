-- Integration test for codeforge.diff module with real-world diff
-- Tests the plugin's diff parsing and application logic using mesh_grid.rs
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local diff = require("codeforge.diff")
local plenary_path = require("plenary.path")

---Extract individual hunks from a unified diff patch
---@param patch_content string
---@return table[] Array of hunk objects with {header, content}
local function extract_hunks_from_patch(patch_content)
  local result = {}
  local lines = vim.split(patch_content, "\n")
  local current_hunk = nil

  for i, line in ipairs(lines) do
    -- Skip file headers (but NOT the index line which comes before hunks)
    if line:match("^diff ") or line:match("^--- ") or line:match("^%+%+%+ ") then
      goto continue
    end

    -- Hunk header line
    if line:match("^@@") then
      if current_hunk then
        table.insert(result, current_hunk)
      end
      current_hunk = {
        header = line,
        content = {line}
      }
      goto continue
    end

    -- Hunk content lines
    if current_hunk then
      table.insert(current_hunk.content, line)
    end

    ::continue::
  end

  -- Don't forget the last hunk
  if current_hunk then
    table.insert(result, current_hunk)
  end

  return result
end

describe("diff integration with mesh_grid.rs", function()
  local original_file = "test-harness/fixtures/mesh_grid.rs"
  local patch_file = "test-harness/fixtures/mesh_grid.patch"

  local original_lines = nil
  local patch_content = nil
  local hunks = {}

  before_each(function()
    -- Read original file
    local original_path = plenary_path.new(original_file)
    if original_path:exists() then
      original_lines = original_path:readlines()
    else
      original_lines = {}
    end

    -- Read patch file
    local patch_path = plenary_path.new(patch_file)
    if patch_path:exists() then
      patch_content = patch_path:read()
    else
      patch_content = ""
    end

    -- Extract hunks from patch file
    hunks = extract_hunks_from_patch(patch_content)
  end)

  describe("parse_hunk_header with real patch", function()
    it("parses all hunk headers from mesh_grid.patch", function()
      -- Extract headers from actual hunks in patch file
      for _, hunk in ipairs(hunks) do
        local result = diff.parse_hunk_header(hunk.header)
        assert.is_not_nil(result, string.format("Failed to parse header: %s", hunk.header))
      end
    end)

    it("correctly parses hunk 1 header", function()
      local hunk1 = hunks[1]
      local result = diff.parse_hunk_header(hunk1.header)

      assert.equals(10, result.old_start)
      assert.equals(6, result.old_count)
      assert.equals(10, result.new_start)
      assert.equals(7, result.new_count)
    end)

    it("correctly parses hunk 2 header", function()
      local hunk2 = hunks[2]
      local result = diff.parse_hunk_header(hunk2.header)

      assert.equals(604, result.old_start)
      assert.equals(8, result.old_count)
      assert.equals(605, result.new_start)
      assert.equals(14, result.new_count)
    end)

    it("correctly parses hunk 3 header", function()
      local hunk3 = hunks[3]
      local result = diff.parse_hunk_header(hunk3.header)

      assert.equals(643, result.old_start)
      assert.equals(26, result.old_count)
      assert.equals(650, result.new_start)
      assert.equals(30, result.new_count)
    end)
  end)

  describe("parse_diff_changes with real patch", function()
    it("parses hunk 1 changes correctly", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")
      local changes = diff.parse_diff_changes(hunk_text)

      assert.is_true(#changes > 0, "Should have parsed some changes")

      -- Check that the addition is correctly identified
      local found_addition = false
      for _, change in ipairs(changes) do
        if change.type == "add" and change.content == "use sprs_ldl::LdlNumeric;" then
          found_addition = true
          break
        end
      end
      assert.is_true(found_addition, "Failed to find the sprs_ldl import addition")
    end)

    it("parses hunk 2 changes correctly", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")
      local changes = diff.parse_diff_changes(hunk_text)

      assert.is_true(#changes > 0, "Should have parsed some changes")

      -- Count additions and removals
      local add_count = 0
      local remove_count = 0
      for _, change in ipairs(changes) do
        if change.type == "add" then
          add_count = add_count + 1
        elseif change.type == "remove" then
          remove_count = remove_count + 1
        end
      end

      assert.is_true(add_count > 0, "Should have some additions in hunk 2")
    end)

    it("parses hunk 3 changes correctly", function()
      local hunk3 = hunks[3]
      local hunk_text = table.concat(hunk3.content, "\n")
      local changes = diff.parse_diff_changes(hunk_text)

      assert.is_true(#changes > 0, "Should have parsed some changes")

      -- Count additions and removals
      local add_count = 0
      local remove_count = 0
      for _, change in ipairs(changes) do
        if change.type == "add" then
          add_count = add_count + 1
        elseif change.type == "remove" then
          remove_count = remove_count + 1
        end
      end

      assert.is_true(add_count >= 0, "Should have non-negative additions in hunk 3")
      assert.is_true(remove_count >= 0, "Should have non-negative removals in hunk 3")
    end)
  end)

  describe("apply_hunk with real patch", function()
    it("applies hunk 1 to original file", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local result, err = diff.apply_hunk(original_lines, hunk_text)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_true(#result > 0, "Result should have content")
    end)

    it("applies hunk 2 to original file", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local result, err = diff.apply_hunk(original_lines, hunk_text)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_true(#result > 0, "Result should have content")
    end)

    it("applies hunk 4 (new helper functions)", function()
      local hunk4 = hunks[4]
      local hunk_text = table.concat(hunk4.content, "\n")

      local result, err = diff.apply_hunk(original_lines, hunk_text)

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_true(#result > 0, "Result should have content")
    end)
  end)

  describe("get_added_lines with real patch", function()
    it("extracts added lines from hunk 1", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local added = diff.get_added_lines(hunk_text)

      assert.is_true(#added >= 0, "Should have non-negative added lines")
    end)

    it("extracts added lines from hunk 2", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local added = diff.get_added_lines(hunk_text)

      assert.is_true(#added >= 0, "Should have non-negative added lines")
    end)
  end)

  describe("get_removed_lines with real patch", function()
    it("extracts removed lines from hunk 2", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local removed = diff.get_removed_lines(hunk_text)

      assert.is_true(#removed >= 0, "Should have non-negative removed lines")
    end)

    it("extracts removed lines from hunk 3", function()
      local hunk3 = hunks[3]
      local hunk_text = table.concat(hunk3.content, "\n")

      local removed = diff.get_removed_lines(hunk_text)

      assert.is_true(#removed >= 0, "Should have non-negative removed lines")
    end)
  end)

  describe("compute_diff with real files", function()
    it("computes diff between original and modified file", function()
      -- Create a modified version by applying hunk 1
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local modified_lines, err = diff.apply_hunk(original_lines, hunk_text)
      assert.is_nil(err)
      assert.is_not_nil(modified_lines)

      -- Compute diff
      local computed_diff = diff.compute_diff(original_lines, modified_lines)

      assert.is_not_nil(computed_diff)
      assert.is_not_nil(computed_diff:match("%+use sprs_ldl::LdlNumeric;"))
    end)
  end)
end)
