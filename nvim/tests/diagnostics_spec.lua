-- Tests for codeforge.diagnostics module
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local diagnostics = require("codeforge.diagnostics")
local store = require("codeforge.store")
local diff = require("codeforge.diff")

describe("diagnostics", function()
  before_each(function()
    -- Create test directory
    vim.fn.mkdir("/tmp/test_codeforge", "p")
    
    -- Reset working directory
    diagnostics.set_working_dir("/tmp/test_codeforge")
    
    -- Clear store
    store.clear()
  end)

  after_each(function()
    -- Clean up test directory
    vim.fn.delete("/tmp/test_codeforge", "rf")
  end)

  describe("is_hunk_redundant", function()
    it("detects redundant hunk when file content matches", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a hunk that would result in the same content
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,3 +1,3 @@\n line1\n line2\n line3",
      }

      -- The hunk should be detected as redundant
      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_true(redundant)

      -- Clean up
      os.remove(test_file)
    end)

    it("returns false when hunk would change content", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a hunk that would change the content
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,3 +1,3 @@\n line1\n+new_line\n line2\n-line3",
      }

      -- The hunk should NOT be detected as redundant
      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_false(redundant)

      -- Clean up
      os.remove(test_file)
    end)

    it("returns false when file doesn't exist", function()
      local hunk = {
        id = "test:nonexistent.lua:0",
        file = "nonexistent.lua",
        diff = "@@ -1,1 +1,2 @@\n+new line",
      }

      local redundant = diagnostics._test_is_hunk_redundant("nonexistent.lua", hunk)
      assert.is_false(redundant)
    end)

    it("handles hunks with additions", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:close()

      -- Create a hunk that adds a line
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,2 +1,3 @@\n line1\n+inserted\n line2",
      }

      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_false(redundant)

      -- Clean up
      os.remove(test_file)
    end)

    it("handles hunks with deletions", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a hunk that deletes a line
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,3 +1,2 @@\n line1\n-line2\n line3",
      }

      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_false(redundant)

      -- Clean up
      os.remove(test_file)
    end)

    it("detects redundant hunk that adds duplicate lines", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a hunk that adds a duplicate line
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,3 +1,4 @@\n line1\n line2\n+line2\n line3",
      }

      -- The hunk should be detected as redundant (adds duplicate line)
      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_true(redundant)

      -- Clean up
      os.remove(test_file)
    end)

    it("does not detect redundant when adding new unique lines", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a hunk that adds a new unique line
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,3 +1,4 @@\n line1\n line2\n+new_unique_line\n line3",
      }

      -- The hunk should NOT be detected as redundant
      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_false(redundant)

      -- Clean up
      os.remove(test_file)
    end)

    it("does not detect redundant when adding mix of existing and new lines", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a hunk that adds both existing and new lines
      local hunk = {
        id = "test:test.lua:0",
        file = "test.lua",
        diff = "@@ -1,3 +1,5 @@\n line1\n line2\n+line2\n+new_line\n line3",
      }

      -- The hunk should NOT be detected as redundant (has new line)
      local redundant = diagnostics._test_is_hunk_redundant("test.lua", hunk)
      assert.is_false(redundant)

      -- Clean up
      os.remove(test_file)
    end)
  end)

  describe("publish_diagnostics with redundant hunks", function()
    it("does not show diagnostics for redundant hunks", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a suggestion with a redundant hunk
      local suggestion = {
        id = "test-suggestion",
        jj_change_id = "abc123",
        description = "Test suggestion",
        files = { "test.lua" },
        hunks = {
          {
            id = "test-suggestion:test.lua:0",
            file = "test.lua",
            diff = "@@ -1,3 +1,3 @@\n line1\n line2\n line3",
            description = "No-op change",
          },
        },
      }

      -- Add suggestion to store
      store.add_suggestion(suggestion)

      -- Create a mock buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, test_file)

      -- Publish diagnostics
      diagnostics.publish_diagnostics(bufnr)

      -- Get diagnostics for the buffer
      local diags = vim.diagnostic.get(bufnr, { namespace = diagnostics._test_get_namespace() })

      -- Should have no diagnostics since the hunk is redundant
      assert.equals(0, #diags)

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
      os.remove(test_file)
    end)

    it("shows diagnostics for non-redundant hunks", function()
      -- Create a test file
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a suggestion with a non-redundant hunk
      local suggestion = {
        id = "test-suggestion",
        jj_change_id = "abc123",
        description = "Test suggestion",
        files = { "test.lua" },
        hunks = {
          {
            id = "test-suggestion:test.lua:0",
            file = "test.lua",
            diff = "@@ -1,3 +1,3 @@\n line1\n+new_line\n line2\n-line3",
            description = "Add new line",
          },
        },
      }

      -- Add suggestion to store
      store.add_suggestion(suggestion)

      -- Create a mock buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, test_file)

      -- Publish diagnostics
      diagnostics.publish_diagnostics(bufnr)

      -- Get diagnostics for the buffer
      local diags = vim.diagnostic.get(bufnr, { namespace = diagnostics._test_get_namespace() })

      -- Should have one diagnostic
      assert.equals(1, #diags)
      assert.equals("Add new line", diags[1].message)

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
      os.remove(test_file)
    end)
  end)

  describe("line offset calculation", function()
    it("shows diagnostics for hunks that extend past end of file", function()
      -- Create a test file with only 3 lines
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a suggestion with a hunk that adds lines at the end
      local suggestion = {
        id = "test-suggestion",
        jj_change_id = "abc123",
        description = "Test suggestion",
        files = { "test.lua" },
        hunks = {
          {
            id = "test-suggestion:test.lua:0",
            file = "test.lua",
            diff = "@@ -3,1 +3,3 @@\n line3\n+line4\n+line5",
            description = "Add lines at end",
          },
        },
      }

      -- Add suggestion to store
      store.add_suggestion(suggestion)

      -- Create a mock buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, test_file)

      -- Publish diagnostics
      diagnostics.publish_diagnostics(bufnr)

      -- Get diagnostics for the buffer
      local diags = vim.diagnostic.get(bufnr, { namespace = diagnostics._test_get_namespace() })

      -- Should have one diagnostic
      assert.equals(1, #diags)
      assert.equals("Add lines at end", diags[1].message)

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
      os.remove(test_file)
    end)

    it("shows diagnostics for hunks that extend past end after offset adjustment", function()
      -- Create a test file with only 3 lines
      local test_file = "/tmp/test_codeforge/test.lua"
      local file = io.open(test_file, "w")
      file:write("line1\n")
      file:write("line2\n")
      file:write("line3\n")
      file:close()

      -- Create a suggestion with two hunks
      -- First hunk adds 2 lines, second hunk adds more lines at the end
      local suggestion = {
        id = "test-suggestion",
        jj_change_id = "abc123",
        description = "Test suggestion",
        files = { "test.lua" },
        hunks = {
          {
            id = "test-suggestion:test.lua:0",
            file = "test.lua",
            diff = "@@ -3,1 +3,3 @@\n line3\n+line4\n+line5",
            description = "Add first batch",
          },
          {
            id = "test-suggestion:test.lua:1",
            file = "test.lua",
            diff = "@@ -5,1 +5,3 @@\n line5\n+line6\n+line7",
            description = "Add second batch",
          },
        },
      }

      -- Add suggestion to store
      store.add_suggestion(suggestion)

      -- Create a mock buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, test_file)

      -- Publish diagnostics
      diagnostics.publish_diagnostics(bufnr)

      -- Get diagnostics for the buffer
      local diags = vim.diagnostic.get(bufnr, { namespace = diagnostics._test_get_namespace() })

      -- Should have two diagnostics
      assert.equals(2, #diags)

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
      os.remove(test_file)
    end)
  end)
end)
