-- Test to reproduce the cursor positioning bug with multiple hunks in a suggestion
-- When opening hunk at L770 without accepting previous hunks in the same suggestion,
-- the cursor should go to line 770, not 839

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")
local store = require("codeforge.store")
local plenary_path = require("plenary.path")

---Extract individual hunks from a unified diff patch
---@param patch_content string
---@return table[] Array of hunk objects with {header, content}
local function extract_hunks_from_patch(patch_content)
  local result = {}
  local lines = vim.split(patch_content, "\n")
  local current_hunk = nil

  for i, line in ipairs(lines) do
    -- Skip file headers
    if line:match("^diff ") or line:match("^index ") or line:match("^--- ") or line:match("^%+%+%+ ") then
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

describe("cursor positioning bug with multiple hunks in suggestion", function()
  local working_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  local original_file = "test-harness/fixtures/mesh_grid.rs"
  local patch_file = "test-harness/fixtures/mesh_grid.patch"

  local original_lines = nil
  local patch_content = nil
  local hunks = {}

  before_each(function()
    -- Clear store
    store.clear()

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

    -- Set working directory for shadow module
    shadow.set_working_dir(working_dir)

    -- Create a suggestion with multiple hunks (simulating tectonic_plate_simulator)
    local suggestion_hunks = {}
    for i, hunk in ipairs(hunks) do
      local hunk_text = table.concat(hunk.content, "\n")
      table.insert(suggestion_hunks, {
        id = "hunk-" .. i,
        file = original_file,
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = diff_utils.parse_hunk_header(hunk.header).old_start,
      })
    end

    -- Add suggestion to store
    store.add_suggestion({
      id = "test-suggestion",
      description = "Test suggestion with multiple hunks",
      hunks = suggestion_hunks,
    })
  end)

  after_each(function()
    -- Clean up shadow buffer after each test
    shadow.close()
    store.clear()
  end)

  describe("opening hunk at L770 without accepting previous hunks", function()
    it("BUG: cursor goes to 839 instead of 770 when previous hunks not accepted", function()
      -- Hunk 5 is at L770: @@ -770,6 +839,59 @@
      -- This hunk adds 53 lines (59 new - 6 old)
      -- When opening this hunk WITHOUT accepting previous hunks (L10, L604, L643, L671),
      -- the cursor should go to line 770 (old_start), not 839 (new_start)

      local hunk5 = hunks[5]
      local hunk_text = table.concat(hunk5.content, "\n")

      local header = diff_utils.parse_hunk_header(hunk5.header)
      print("Hunk 5 header:", hunk5.header)
      print("Parsed header - old_start:", header.old_start, "old_count:", header.old_count)
      print("Parsed header - new_start:", header.new_start, "new_count:", header.new_count)

      -- Create hunk object with ID that matches the suggestion
      local hunk = {
        id = "hunk-5",
        file = original_file,
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 770,
      }

      -- Open the hunk - this should trigger the offset calculation bug
      local _, win = shadow.open(hunk, working_dir)

      -- Get cursor position
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = cursor[1]

      print("Cursor position:", cursor_line)
      print("Expected (old_start):", header.old_start)
      print("BUG: cursor is at new_start:", header.new_start)

      -- BUG: The cursor goes to 839 (new_start) instead of 770 (old_start)
      -- This happens because the plugin calculates an offset from previous hunks
      -- even though they haven't been accepted yet
      assert.equals(header.old_start, cursor_line, "Cursor should be at old_start (770), not new_start (839)")
    end)

    it("BUG: highlights wrong region when previous hunks not accepted", function()
      -- When opening hunk at L770 without accepting previous hunks,
      -- it should only highlight the hunk region (lines 770-828)
      -- But the bug causes it to highlight from 839 to the end

      local hunk5 = hunks[5]
      local hunk_text = table.concat(hunk5.content, "\n")

      local header = diff_utils.parse_hunk_header(hunk5.header)

      -- Create hunk object with ID that matches the suggestion
      local hunk = {
        id = "hunk-5",
        file = original_file,
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 770,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Get all highlights
      local ns = vim.api.nvim_create_namespace("codeforge_shadow")
      local highlights = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

      -- Count DiffAdd highlights
      local diff_add_count = 0
      local first_highlight_line = nil
      local last_highlight_line = nil

      for _, hl in ipairs(highlights) do
        local details = hl[4]
        if details and details.hl_group == "DiffAdd" then
          local line = hl[2] + 1  -- Convert to 1-indexed
          diff_add_count = diff_add_count + 1
          if not first_highlight_line then
            first_highlight_line = line
          end
          last_highlight_line = line
        end
      end

      print("Number of DiffAdd highlights:", diff_add_count)
      print("First highlight at line:", first_highlight_line)
      print("Last highlight at line:", last_highlight_line)
      print("Buffer line count:", vim.api.nvim_buf_line_count(buf))

      -- Count actual added lines in the hunk
      local changes = diff_utils.parse_diff_changes(hunk_text)
      local actual_additions = 0
      for _, change in ipairs(changes) do
        if change.type == "add" then
          actual_additions = actual_additions + 1
        end
      end

      print("Actual additions in hunk:", actual_additions)

      -- BUG: The hunk should only highlight the added lines (53)
      -- This test will FAIL until the bug is fixed
      assert.equals(actual_additions, diff_add_count, "Should only highlight added lines, not entire hunk region")
    end)
  end)

  describe("opening hunk at L778 without accepting previous hunks", function()
    it("BUG: cursor goes to bottom of file instead of 778", function()
      -- Hunk 6 is at L778: @@ -778,34 +900,34 @@
      -- This hunk is in the test section
      -- When opening this hunk WITHOUT accepting previous hunks,
      -- the cursor should go to line 778, not the bottom of the file

      local hunk6 = hunks[6]
      local hunk_text = table.concat(hunk6.content, "\n")

      local header = diff_utils.parse_hunk_header(hunk6.header)
      print("Hunk 6 header:", hunk6.header)
      print("Parsed header - old_start:", header.old_start, "old_count:", header.old_count)
      print("Parsed header - new_start:", header.new_start, "new_count:", header.new_count)

      -- Create hunk object with ID that matches the suggestion
      local hunk = {
        id = "hunk-6",
        file = original_file,
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 778,
      }

      local _, win = shadow.open(hunk, working_dir)

      -- Get cursor position
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = cursor[1]

      print("Cursor position:", cursor_line)
      print("Expected (old_start):", header.old_start)
      print("Buffer line count:", vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))

      -- BUG: The cursor goes to the bottom of the file instead of 778
      -- This test will FAIL until the bug is fixed
      assert.equals(header.old_start, cursor_line, "Cursor should be at old_start (778), not bottom of file")
    end)
  end)

  describe("opening hunk at L818 without accepting previous hunks", function()
    it("BUG: cursor goes to bottom of file instead of 818", function()
      -- Hunk 7 is at L818: @@ -818,11 +940,11 @@
      -- This hunk is also in the test section
      -- When opening this hunk WITHOUT accepting previous hunks,
      -- the cursor should go to line 818, not the bottom of the file

      local hunk7 = hunks[7]
      local hunk_text = table.concat(hunk7.content, "\n")

      local header = diff_utils.parse_hunk_header(hunk7.header)
      print("Hunk 7 header:", hunk7.header)
      print("Parsed header - old_start:", header.old_start, "old_count:", header.old_count)
      print("Parsed header - new_start:", header.new_start, "new_count:", header.new_count)

      -- Create hunk object with ID that matches the suggestion
      local hunk = {
        id = "hunk-7",
        file = original_file,
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 818,
      }

      local _, win = shadow.open(hunk, working_dir)

      -- Get cursor position
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = cursor[1]

      print("Cursor position:", cursor_line)
      print("Expected (old_start):", header.old_start)
      print("Buffer line count:", vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)))

      -- BUG: The cursor goes to the bottom of the file instead of 818
      -- This test will FAIL until the bug is fixed
      assert.equals(header.old_start, cursor_line, "Cursor should be at old_start (818), not bottom of file")
    end)
  end)
end)
