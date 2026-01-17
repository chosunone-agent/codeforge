-- Integration test for codeforge shadow buffer and diff highlighting
-- Tests the actual neovim plugin behavior with mesh_grid.rs patch
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")
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

describe("shadow buffer integration with mesh_grid.rs", function()
  local working_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
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

    -- Set working directory for shadow module
    shadow.set_working_dir(working_dir)
  end)

  after_each(function()
    -- Clean up shadow buffer after each test
    shadow.close()
  end)

  describe("shadow buffer creation", function()
    it("creates a shadow buffer for hunk 1", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      local buf, win = shadow.open(hunk, working_dir)

      assert.is_not_nil(buf, "Shadow buffer should be created")
      assert.is_not_nil(win, "Shadow window should be created")
      assert.is_true(vim.api.nvim_buf_is_valid(buf), "Buffer should be valid")
      assert.is_true(vim.api.nvim_win_is_valid(win), "Window should be valid")

      -- Check buffer has the correct content
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(#buf_lines > 0, "Buffer should have content")

      -- Check that the import was added
      local found_import = false
      for _, line in ipairs(buf_lines) do
        if line:match("use sprs_ldl::LdlNumeric;") then
          found_import = true
          break
        end
      end
      assert.is_true(found_import, "Import should be in shadow buffer")
    end)

    it("creates a shadow buffer for hunk 2", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local hunk = {
        id = "test-hunk-2",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 604,
      }

      local buf, win = shadow.open(hunk, working_dir)

      assert.is_not_nil(buf)
      assert.is_not_nil(win)

      -- Check that new lines are present
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local has_north_pole = false
      local has_new_call = false

      for _, line in ipairs(buf_lines) do
        if line:match("let north_pole_idx = Self::find_north_pole_vertex") then
          has_north_pole = true
        end
        if line:match("let edge_transport_connection = Self::calculate_trivial_connection%(") then
          has_new_call = true
        end
      end

      assert.is_true(has_north_pole, "North pole line should be in shadow buffer")
      assert.is_true(has_new_call, "New function call should be in shadow buffer")
    end)
  end)

  describe("diff highlighting", function()
    it("applies DiffAdd highlighting to added lines in hunk 1", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Get highlights from the buffer
      local ns = vim.api.nvim_create_namespace("codeforge_shadow")
      local highlights = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

      -- Should have at least one highlight (the added line)
      assert.is_true(#highlights > 0, "Should have diff highlights")

      -- Check that the import line is highlighted
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local import_line_num = nil
      for i, line in ipairs(buf_lines) do
        if line:match("use sprs_ldl::LdlNumeric;") then
          import_line_num = i - 1  -- 0-indexed
          break
        end
      end

      assert.is_not_nil(import_line_num, "Import line should exist")

      -- Check that this line has DiffAdd highlight
      local line_highlights = vim.api.nvim_buf_get_extmarks(buf, ns, {import_line_num, 0}, {import_line_num, -1}, { details = true })
      local has_diff_add = false
      for _, hl in ipairs(line_highlights) do
        local details = hl[4]
        if details and details.hl_group == "DiffAdd" then
          has_diff_add = true
          break
        end
      end

      assert.is_true(has_diff_add, "Import line should have DiffAdd highlight")
    end)

    it("applies DiffAdd highlighting to multiple added lines in hunk 2", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local hunk = {
        id = "test-hunk-2",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 604,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Get all highlights
      local ns = vim.api.nvim_create_namespace("codeforge_shadow")
      local highlights = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

      -- Count DiffAdd highlights
      local diff_add_count = 0
      for _, hl in ipairs(highlights) do
        local details = hl[4]
        if details and details.hl_group == "DiffAdd" then
          diff_add_count = diff_add_count + 1
        end
      end

      assert.is_true(diff_add_count > 0, "Should have DiffAdd highlights for hunk 2")
    end)
  end)

  describe("extmark boundaries", function()
    it("places boundary extmarks at hunk start and end", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Get boundary extmarks
      local ns_boundaries = vim.api.nvim_create_namespace("codeforge_boundaries")
      local boundaries = vim.api.nvim_buf_get_extmarks(buf, ns_boundaries, 0, -1, { details = true })

      -- Should have at least 2 boundaries (start and end)
      assert.is_true(#boundaries >= 2, "Should have boundary extmarks")

      -- Check for start boundary (┌) and end boundary (└)
      -- Neovim pads sign_text to 4 characters, so we check if the character is present
      local has_start = false
      local has_end = false
      for _, mark in ipairs(boundaries) do
        local details = mark[4]
        if details and details.sign_text then
          -- Check if the character is in the sign_text (handles UTF-8 and padding)
          if details.sign_text:find("┌") then
            has_start = true
          elseif details.sign_text:find("└") then
            has_end = true
          end
        end
      end

      assert.is_true(has_start, "Should have start boundary (┌)")
      assert.is_true(has_end, "Should have end boundary (└)")
    end)

    it("places │ signs between boundaries", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local hunk = {
        id = "test-hunk-2",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 604,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Get boundary extmarks
      local ns_boundaries = vim.api.nvim_create_namespace("codeforge_boundaries")
      local boundaries = vim.api.nvim_buf_get_extmarks(buf, ns_boundaries, 0, -1, { details = true })

      -- Count │ signs - Neovim pads sign_text to 4 characters
      local pipe_count = 0
      for _, mark in ipairs(boundaries) do
        local details = mark[4]
        if details and details.sign_text then
          -- Check if the character is in the sign_text (handles UTF-8 and padding)
          if details.sign_text:find("│") then
            pipe_count = pipe_count + 1
          end
        end
      end

      -- Should have │ signs between start and end
      assert.is_true(pipe_count > 0, "Should have │ signs between boundaries")
    end)
  end)

  describe("cursor positioning", function()
    it("moves cursor to the hunk location", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      local _, win = shadow.open(hunk, working_dir)

      -- Get cursor position
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = cursor[1]

      -- Cursor should be at or near the hunk location (line 10)
      -- The exact position depends on how the hunk is applied
      assert.is_true(cursor_line >= 1, "Cursor should be at a valid line")
      assert.is_true(cursor_line <= 20, "Cursor should be near the hunk (within 10 lines)")
    end)

    it("moves cursor to the start of added lines", function()
      local hunk2 = hunks[2]
      local hunk_text = table.concat(hunk2.content, "\n")

      local hunk = {
        id = "test-hunk-2",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 604,
      }

      local _, win = shadow.open(hunk, working_dir)

      -- Get cursor position
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = cursor[1]

      -- Cursor should be at or near the hunk location (line 604)
      assert.is_true(cursor_line >= 595, "Cursor should be near the hunk")
      assert.is_true(cursor_line <= 615, "Cursor should be near the hunk")
    end)
  end)

  describe("hunk region tracking", function()
    it("tracks the editable hunk region", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      shadow.open(hunk, working_dir)

      -- Get hunk region
      local region = shadow.get_hunk_region()

      assert.is_not_nil(region, "Hunk region should be tracked")
      assert.is_not_nil(region.start_line, "Region should have start_line")
      assert.is_not_nil(region.end_line, "Region should have end_line")
      assert.is_true(region.start_line <= region.end_line, "Start should be before or equal to end")
    end)

    it("returns current boundaries from extmarks", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      shadow.open(hunk, working_dir)

      -- Get current boundaries
      local start_line, end_line = shadow.get_current_boundaries()

      assert.is_not_nil(start_line, "Should have start boundary")
      assert.is_not_nil(end_line, "Should have end boundary")
      assert.is_true(start_line <= end_line, "Start should be before or equal to end")
    end)
  end)

  describe("buffer state", function()
    it("sets buffer options correctly", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Check buffer options
      local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
      local bufhidden = vim.api.nvim_buf_get_option(buf, "bufhidden")
      local swapfile = vim.api.nvim_buf_get_option(buf, "swapfile")
      local modified = vim.api.nvim_buf_get_option(buf, "modified")
      local filetype = vim.api.nvim_buf_get_option(buf, "filetype")

      assert.equals("acwrite", buftype, "Buffer should have buftype=acwrite")
      assert.equals("hide", bufhidden, "Buffer should have bufhidden=hide")
      assert.is_false(swapfile, "Buffer should not have swapfile")
      assert.is_false(modified, "Buffer should not be modified initially")
      assert.equals("rust", filetype, "Buffer should have filetype=rust")
    end)

    it("marks buffer as codeforge shadow", function()
      local hunk1 = hunks[1]
      local hunk_text = table.concat(hunk1.content, "\n")

      local hunk = {
        id = "test-hunk-1",
        file = "test-harness/fixtures/mesh_grid.rs",
        diff = hunk_text,
        originalLines = original_lines,
        originalStartLine = 10,
      }

      local buf, _ = shadow.open(hunk, working_dir)

      -- Check buffer variables
      local is_shadow = pcall(function()
        return vim.api.nvim_buf_get_var(buf, "codeforge_shadow")
      end)

      assert.is_true(is_shadow, "Buffer should be marked as codeforge_shadow")
    end)
  end)
end)
