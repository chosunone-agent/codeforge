-- Comprehensive test for shadow buffer highlighting with multiple hunks
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Mock store module for tests
local mock_store = {
  cache_original_content = function() end,
  get_original_content = function() return nil end,
  get_suggestion_by_hunk_id = function(hunk_id)
    -- Return the mock suggestion with all hunks
    return mock_suggestion
  end,
}
package.loaded["codeforge.store"] = mock_store

local shadow = require("codeforge.ui.shadow")
local diff_utils = require("codeforge.diff")

-- Create a comprehensive mock suggestion with 15 hunks that significantly extend the file
-- Each hunk adds 30-40 lines to test cumulative offsets
-- Includes hunks near the end of the file
local mock_suggestion = {
  id = "test-suggestion",
  hunks = {
    {
      id = "test-suggestion:test.lua:0",
      file = "test.lua",
      diff = "@@ -10,3 +10,35 @@\n line10\n+added10_1\n+added10_2\n+added10_3\n+added10_4\n+added10_5\n+added10_6\n+added10_7\n+added10_8\n+added10_9\n+added10_10\n+added10_11\n+added10_12\n+added10_13\n+added10_14\n+added10_15\n+added10_16\n+added10_17\n+added10_18\n+added10_19\n+added10_20\n+added10_21\n+added10_22\n+added10_23\n+added10_24\n+added10_25\n+added10_26\n+added10_27\n+added10_28\n+added10_29\n+added10_30\n+added10_31\n+added10_32\n line11\n line12",
    },
    {
      id = "test-suggestion:test.lua:1",
      file = "test.lua",
      diff = "@@ -50,2 +52,34 @@\n line50\n+added50_1\n+added50_2\n+added50_3\n+added50_4\n+added50_5\n+added50_6\n+added50_7\n+added50_8\n+added50_9\n+added50_10\n+added50_11\n+added50_12\n+added50_13\n+added50_14\n+added50_15\n+added50_16\n+added50_17\n+added50_18\n+added50_19\n+added50_20\n+added50_21\n+added50_22\n+added50_23\n+added50_24\n+added50_25\n+added50_26\n+added50_27\n+added50_28\n+added50_29\n+added50_30\n+added50_31\n+added50_32\n line51",
    },
    {
      id = "test-suggestion:test.lua:2",
      file = "test.lua",
      diff = "@@ -100,3 +104,35 @@\n line100\n+added100_1\n+added100_2\n+added100_3\n+added100_4\n+added100_5\n+added100_6\n+added100_7\n+added100_8\n+added100_9\n+added100_10\n+added100_11\n+added100_12\n+added100_13\n+added100_14\n+added100_15\n+added100_16\n+added100_17\n+added100_18\n+added100_19\n+added100_20\n+added100_21\n+added100_22\n+added100_23\n+added100_24\n+added100_25\n+added100_26\n+added100_27\n+added100_28\n+added100_29\n+added100_30\n+added100_31\n+added100_32\n line101\n line102",
    },
    {
      id = "test-suggestion:test.lua:3",
      file = "test.lua",
      diff = "@@ -150,2 +156,34 @@\n line150\n+added150_1\n+added150_2\n+added150_3\n+added150_4\n+added150_5\n+added150_6\n+added150_7\n+added150_8\n+added150_9\n+added150_10\n+added150_11\n+added150_12\n+added150_13\n+added150_14\n+added150_15\n+added150_16\n+added150_17\n+added150_18\n+added150_19\n+added150_20\n+added150_21\n+added150_22\n+added150_23\n+added150_24\n+added150_25\n+added150_26\n+added150_27\n+added150_28\n+added150_29\n+added150_30\n+added150_31\n+added150_32\n line151",
    },
    {
      id = "test-suggestion:test.lua:4",
      file = "test.lua",
      diff = "@@ -200,3 +208,35 @@\n line200\n+added200_1\n+added200_2\n+added200_3\n+added200_4\n+added200_5\n+added200_6\n+added200_7\n+added200_8\n+added200_9\n+added200_10\n+added200_11\n+added200_12\n+added200_13\n+added200_14\n+added200_15\n+added200_16\n+added200_17\n+added200_18\n+added200_19\n+added200_20\n+added200_21\n+added200_22\n+added200_23\n+added200_24\n+added200_25\n+added200_26\n+added200_27\n+added200_28\n+added200_29\n+added200_30\n+added200_31\n+added200_32\n line201\n line202",
    },
    {
      id = "test-suggestion:test.lua:5",
      file = "test.lua",
      diff = "@@ -250,2 +260,34 @@\n line250\n+added250_1\n+added250_2\n+added250_3\n+added250_4\n+added250_5\n+added250_6\n+added250_7\n+added250_8\n+added250_9\n+added250_10\n+added250_11\n+added250_12\n+added250_13\n+added250_14\n+added250_15\n+added250_16\n+added250_17\n+added250_18\n+added250_19\n+added250_20\n+added250_21\n+added250_22\n+added250_23\n+added250_24\n+added250_25\n+added250_26\n+added250_27\n+added250_28\n+added250_29\n+added250_30\n+added250_31\n+added250_32\n line251",
    },
    {
      id = "test-suggestion:test.lua:6",
      file = "test.lua",
      diff = "@@ -300,3 +312,35 @@\n line300\n+added300_1\n+added300_2\n+added300_3\n+added300_4\n+added300_5\n+added300_6\n+added300_7\n+added300_8\n+added300_9\n+added300_10\n+added300_11\n+added300_12\n+added300_13\n+added300_14\n+added300_15\n+added300_16\n+added300_17\n+added300_18\n+added300_19\n+added300_20\n+added300_21\n+added300_22\n+added300_23\n+added300_24\n+added300_25\n+added300_26\n+added300_27\n+added300_28\n+added300_29\n+added300_30\n+added300_31\n+added300_32\n line301\n line302",
    },
    {
      id = "test-suggestion:test.lua:7",
      file = "test.lua",
      diff = "@@ -350,2 +364,34 @@\n line350\n+added350_1\n+added350_2\n+added350_3\n+added350_4\n+added350_5\n+added350_6\n+added350_7\n+added350_8\n+added350_9\n+added350_10\n+added350_11\n+added350_12\n+added350_13\n+added350_14\n+added350_15\n+added350_16\n+added350_17\n+added350_18\n+added350_19\n+added350_20\n+added350_21\n+added350_22\n+added350_23\n+added350_24\n+added350_25\n+added350_26\n+added350_27\n+added350_28\n+added350_29\n+added350_30\n+added350_31\n+added350_32\n line351",
    },
    {
      id = "test-suggestion:test.lua:8",
      file = "test.lua",
      diff = "@@ -400,3 +416,35 @@\n line400\n+added400_1\n+added400_2\n+added400_3\n+added400_4\n+added400_5\n+added400_6\n+added400_7\n+added400_8\n+added400_9\n+added400_10\n+added400_11\n+added400_12\n+added400_13\n+added400_14\n+added400_15\n+added400_16\n+added400_17\n+added400_18\n+added400_19\n+added400_20\n+added400_21\n+added400_22\n+added400_23\n+added400_24\n+added400_25\n+added400_26\n+added400_27\n+added400_28\n+added400_29\n+added400_30\n+added400_31\n+added400_32\n line401\n line402",
    },
    {
      id = "test-suggestion:test.lua:9",
      file = "test.lua",
      diff = "@@ -450,2 +468,34 @@\n line450\n+added450_1\n+added450_2\n+added450_3\n+added450_4\n+added450_5\n+added450_6\n+added450_7\n+added450_8\n+added450_9\n+added450_10\n+added450_11\n+added450_12\n+added450_13\n+added450_14\n+added450_15\n+added450_16\n+added450_17\n+added450_18\n+added450_19\n+added450_20\n+added450_21\n+added450_22\n+added450_23\n+added450_24\n+added450_25\n+added450_26\n+added450_27\n+added450_28\n+added450_29\n+added450_30\n+added450_31\n+added450_32\n line451",
    },
    {
      id = "test-suggestion:test.lua:10",
      file = "test.lua",
      diff = "@@ -500,3 +520,35 @@\n line500\n+added500_1\n+added500_2\n+added500_3\n+added500_4\n+added500_5\n+added500_6\n+added500_7\n+added500_8\n+added500_9\n+added500_10\n+added500_11\n+added500_12\n+added500_13\n+added500_14\n+added500_15\n+added500_16\n+added500_17\n+added500_18\n+added500_19\n+added500_20\n+added500_21\n+added500_22\n+added500_23\n+added500_24\n+added500_25\n+added500_26\n+added500_27\n+added500_28\n+added500_29\n+added500_30\n+added500_31\n+added500_32\n line501\n line502",
    },
    {
      id = "test-suggestion:test.lua:11",
      file = "test.lua",
      diff = "@@ -550,2 +572,34 @@\n line550\n+added550_1\n+added550_2\n+added550_3\n+added550_4\n+added550_5\n+added550_6\n+added550_7\n+added550_8\n+added550_9\n+added550_10\n+added550_11\n+added550_12\n+added550_13\n+added550_14\n+added550_15\n+added550_16\n+added550_17\n+added550_18\n+added550_19\n+added550_20\n+added550_21\n+added550_22\n+added550_23\n+added550_24\n+added550_25\n+added550_26\n+added550_27\n+added550_28\n+added550_29\n+added550_30\n+added550_31\n+added550_32\n line551",
    },
    {
      id = "test-suggestion:test.lua:12",
      file = "test.lua",
      diff = "@@ -600,3 +624,35 @@\n line600\n+added600_1\n+added600_2\n+added600_3\n+added600_4\n+added600_5\n+added600_6\n+added600_7\n+added600_8\n+added600_9\n+added600_10\n+added600_11\n+added600_12\n+added600_13\n+added600_14\n+added600_15\n+added600_16\n+added600_17\n+added600_18\n+added600_19\n+added600_20\n+added600_21\n+added600_22\n+added600_23\n+added600_24\n+added600_25\n+added600_26\n+added600_27\n+added600_28\n+added600_29\n+added600_30\n+added600_31\n+added600_32\n line601\n line602",
    },
    {
      id = "test-suggestion:test.lua:13",
      file = "test.lua",
      diff = "@@ -650,2 +676,34 @@\n line650\n+added650_1\n+added650_2\n+added650_3\n+added650_4\n+added650_5\n+added650_6\n+added650_7\n+added650_8\n+added650_9\n+added650_10\n+added650_11\n+added650_12\n+added650_13\n+added650_14\n+added650_15\n+added650_16\n+added650_17\n+added650_18\n+added650_19\n+added650_20\n+added650_21\n+added650_22\n+added650_23\n+added650_24\n+added650_25\n+added650_26\n+added650_27\n+added650_28\n+added650_29\n+added650_30\n+added650_31\n+added650_32\n line651",
    },
    {
      id = "test-suggestion:test.lua:14",
      file = "test.lua",
      diff = "@@ -700,3 +728,35 @@\n line700\n+added700_1\n+added700_2\n+added700_3\n+added700_4\n+added700_5\n+added700_6\n+added700_7\n+added700_8\n+added700_9\n+added700_10\n+added700_11\n+added700_12\n+added700_13\n+added700_14\n+added700_15\n+added700_16\n+added700_17\n+added700_18\n+added700_19\n+added700_20\n+added700_21\n+added700_22\n+added700_23\n+added700_24\n+added700_25\n+added700_26\n+added700_27\n+added700_28\n+added700_29\n+added700_30\n+added700_31\n+added700_32\n line701\n line702",
    },
    {
      id = "test-suggestion:test.lua:15",
      file = "test.lua",
      diff = "@@ -750,2 +780,34 @@\n line750\n+added750_1\n+added750_2\n+added750_3\n+added750_4\n+added750_5\n+added750_6\n+added750_7\n+added750_8\n+added750_9\n+added750_10\n+added750_11\n+added750_12\n+added750_13\n+added750_14\n+added750_15\n+added750_16\n+added750_17\n+added750_18\n+added750_19\n+added750_20\n+added750_21\n+added750_22\n+added750_23\n+added750_24\n+added750_25\n+added750_26\n+added750_27\n+added750_28\n+added750_29\n+added750_30\n+added750_31\n+added750_32\n line751",
    },
    {
      id = "test-suggestion:test.lua:16",
      file = "test.lua",
      diff = "@@ -800,3 +832,35 @@\n line800\n+added800_1\n+added800_2\n+added800_3\n+added800_4\n+added800_5\n+added800_6\n+added800_7\n+added800_8\n+added800_9\n+added800_10\n+added800_11\n+added800_12\n+added800_13\n+added800_14\n+added800_15\n+added800_16\n+added800_17\n+added800_18\n+added800_19\n+added800_20\n+added800_21\n+added800_22\n+added800_23\n+added800_24\n+added800_25\n+added800_26\n+added800_27\n+added800_28\n+added800_29\n+added800_30\n+added800_31\n+added800_32\n line801\n line802",
    },
    {
      id = "test-suggestion:test.lua:17",
      file = "test.lua",
      diff = "@@ -850,2 +884,34 @@\n line850\n+added850_1\n+added850_2\n+added850_3\n+added850_4\n+added850_5\n+added850_6\n+added850_7\n+added850_8\n+added850_9\n+added850_10\n+added850_11\n+added850_12\n+added850_13\n+added850_14\n+added850_15\n+added850_16\n+added850_17\n+added850_18\n+added850_19\n+added850_20\n+added850_21\n+added850_22\n+added850_23\n+added850_24\n+added850_25\n+added850_26\n+added850_27\n+added850_28\n+added850_29\n+added850_30\n+added850_31\n+added850_32\n line851",
    },
    {
      id = "test-suggestion:test.lua:18",
      file = "test.lua",
      diff = "@@ -900,3 +936,35 @@\n line900\n+added900_1\n+added900_2\n+added900_3\n+added900_4\n+added900_5\n+added900_6\n+added900_7\n+added900_8\n+added900_9\n+added900_10\n+added900_11\n+added900_12\n+added900_13\n+added900_14\n+added900_15\n+added900_16\n+added900_17\n+added900_18\n+added900_19\n+added900_20\n+added900_21\n+added900_22\n+added900_23\n+added900_24\n+added900_25\n+added900_26\n+added900_27\n+added900_28\n+added900_29\n+added900_30\n+added900_31\n+added900_32\n line901\n line902",
    },
    {
      id = "test-suggestion:test.lua:19",
      file = "test.lua",
      diff = "@@ -950,2 +988,34 @@\n line950\n+added950_1\n+added950_2\n+added950_3\n+added950_4\n+added950_5\n+added950_6\n+added950_7\n+added950_8\n+added950_9\n+added950_10\n+added950_11\n+added950_12\n+added950_13\n+added950_14\n+added950_15\n+added950_16\n+added950_17\n+added950_18\n+added950_19\n+added950_20\n+added950_21\n+added950_22\n+added950_23\n+added950_24\n+added950_25\n+added950_26\n+added950_27\n+added950_28\n+added950_29\n+added950_30\n+added950_31\n+added950_32\n line951",
    },
    {
      id = "test-suggestion:test.lua:20",
      file = "test.lua",
      diff = "@@ -980,3 +1016,35 @@\n line980\n+added980_1\n+added980_2\n+added980_3\n+added980_4\n+added980_5\n+added980_6\n+added980_7\n+added980_8\n+added980_9\n+added980_10\n+added980_11\n+added980_12\n+added980_13\n+added980_14\n+added980_15\n+added980_16\n+added980_17\n+added980_18\n+added980_19\n+added980_20\n+added980_21\n+added980_22\n+added980_23\n+added980_24\n+added980_25\n+added980_26\n+added980_27\n+added980_28\n+added980_29\n+added980_30\n+added980_31\n+added980_32\n line981\n line982",
    },
  },
}

describe("shadow highlighting with multiple hunks", function()
  after_each(function()
    -- Clean up any open shadow buffers
    shadow.close()
  end)

  it("highlights all hunks correctly with cumulative offsets", function()
    -- Create a test file with 1200 lines
    local test_file = "/tmp/test_codeforge_comprehensive/test.lua"
    vim.fn.mkdir("/tmp/test_codeforge_comprehensive", "p")
    local file = io.open(test_file, "w")
    for i = 1, 1200 do
      file:write("line" .. i .. "\n")
    end
    file:close()

    -- Set working directory
    shadow.set_working_dir("/tmp/test_codeforge_comprehensive")

    -- Test each hunk
    for i, hunk in ipairs(mock_suggestion.hunks) do
      -- Open shadow buffer for this hunk
      local buf, win = shadow.open(hunk, "/tmp/test_codeforge_comprehensive")

      -- Verify buffer was created
      assert.is_not_nil(buf)
      assert.is_true(vim.api.nvim_buf_is_valid(buf))

      -- Get the buffer content
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Parse the hunk to get expected added lines
      local changes = diff_utils.parse_diff_changes(hunk.diff)
      local expected_added_lines = {}
      for _, change in ipairs(changes) do
        if change.type == "add" then
          table.insert(expected_added_lines, change.content)
        end
      end

      -- Get highlights from the buffer
      local highlights = vim.api.nvim_buf_get_extmarks(buf, -1, {0, 0}, {-1, -1}, {details = true})

      -- Find all DiffAdd highlights
      local added_line_highlights = {}
      for _, mark in ipairs(highlights) do
        local row = mark[2]
        local details = mark[4]
        if details and details.hl_group == "DiffAdd" then
          table.insert(added_line_highlights, row)
        end
      end

      -- Verify we have the correct number of highlights
      assert.equals(#expected_added_lines, #added_line_highlights, 
        string.format("Hunk %d: Expected %d highlights, got %d", i, #expected_added_lines, #added_line_highlights))

      -- Verify the content of each highlighted line matches the expected content
      for j, row in ipairs(added_line_highlights) do
        local actual_content = content[row + 1]  -- +1 because content is 1-indexed
        local expected_content = expected_added_lines[j]
        assert.equals(expected_content, actual_content,
          string.format("Hunk %d, highlight %d: Expected '%s', got '%s'", i, j, expected_content, actual_content))
      end

      -- Close the shadow buffer before testing the next hunk
      shadow.close()
    end

    -- Clean up
    os.remove(test_file)
    vim.fn.delete("/tmp/test_codeforge_comprehensive", "rf")
  end)
end)
