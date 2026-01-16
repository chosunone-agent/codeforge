-- Tests for codeforge.store module
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local store = require("codeforge.store")

describe("store", function()
  before_each(function()
    store.clear()
  end)

  describe("connection state", function()
    it("starts disconnected", function()
      assert.is_false(store.is_connected())
    end)

    it("can set connected state", function()
      store.set_connected(true)
      assert.is_true(store.is_connected())
      
      store.set_connected(false)
      assert.is_false(store.is_connected())
    end)

    it("emits events on connection change", function()
      local connect_called = false
      local disconnect_called = false
      
      store.on("on_connect", function()
        connect_called = true
      end)
      
      store.on("on_disconnect", function()
        disconnect_called = true
      end)
      
      store.set_connected(true)
      assert.is_true(connect_called)
      
      store.set_connected(false)
      assert.is_true(disconnect_called)
    end)
  end)

  describe("add_suggestion", function()
    local test_suggestion = {
      id = "test-1",
      jjChangeId = "abc123",
      description = "Test suggestion",
      files = { "file1.lua", "file2.lua" },
      hunks = {
        { id = "test-1:file1.lua:0", file = "file1.lua", diff = "@@ -1 +1 @@\n-old\n+new" },
        { id = "test-1:file2.lua:0", file = "file2.lua", diff = "@@ -1 +1 @@\n-a\n+b" },
      },
    }

    it("adds a suggestion", function()
      store.add_suggestion(test_suggestion)
      
      local suggestions = store.get_suggestions()
      assert.equals(1, #suggestions)
      assert.equals("test-1", suggestions[1].id)
    end)

    it("initializes hunk states as pending", function()
      store.add_suggestion(test_suggestion)
      
      local state1 = store.get_hunk_state("test-1:file1.lua:0")
      local state2 = store.get_hunk_state("test-1:file2.lua:0")
      
      assert.is_not_nil(state1)
      assert.equals("pending", state1.status)
      assert.is_not_nil(state2)
      assert.equals("pending", state2.status)
    end)

    it("sets first suggestion as current", function()
      store.add_suggestion(test_suggestion)
      
      local current = store.get_current_suggestion()
      assert.is_not_nil(current)
      assert.equals("test-1", current.id)
    end)

    it("skips suggestions without hunks", function()
      local empty_suggestion = {
        id = "empty-1",
        jjChangeId = "xyz",
        description = "Empty",
        files = {},
        hunks = {},
      }
      
      store.add_suggestion(empty_suggestion)
      
      assert.equals(0, #store.get_suggestions())
    end)

    it("emits on_suggestion_ready for new suggestions", function()
      local emitted_suggestion = nil
      store.on("on_suggestion_ready", function(s)
        emitted_suggestion = s
      end)
      
      store.add_suggestion(test_suggestion)
      
      assert.is_not_nil(emitted_suggestion)
      assert.equals("test-1", emitted_suggestion.id)
    end)
  end)

  describe("remove_suggestion", function()
    local test_suggestion = {
      id = "test-1",
      jjChangeId = "abc123",
      description = "Test",
      files = { "file.lua" },
      hunks = {
        { id = "test-1:file.lua:0", file = "file.lua", diff = "diff" },
      },
    }

    it("removes a suggestion", function()
      store.add_suggestion(test_suggestion)
      assert.equals(1, #store.get_suggestions())
      
      store.remove_suggestion("test-1")
      assert.equals(0, #store.get_suggestions())
    end)

    it("clears current if removed was current", function()
      store.add_suggestion(test_suggestion)
      assert.equals("test-1", store.get_current_suggestion().id)
      
      store.remove_suggestion("test-1")
      assert.is_nil(store.get_current_suggestion())
    end)

    it("sets next suggestion as current when current is removed", function()
      local suggestion2 = {
        id = "test-2",
        jjChangeId = "def456",
        description = "Test 2",
        files = { "file2.lua" },
        hunks = {
          { id = "test-2:file2.lua:0", file = "file2.lua", diff = "diff2" },
        },
      }
      
      store.add_suggestion(test_suggestion)
      store.add_suggestion(suggestion2)
      
      store.remove_suggestion("test-1")
      
      assert.is_not_nil(store.get_current_suggestion())
      assert.equals("test-2", store.get_current_suggestion().id)
    end)
  end)

  describe("hunk navigation", function()
    local test_suggestion = {
      id = "test-1",
      jjChangeId = "abc123",
      description = "Test",
      files = { "file.lua" },
      hunks = {
        { id = "hunk-1", file = "file.lua", diff = "diff1" },
        { id = "hunk-2", file = "file.lua", diff = "diff2" },
        { id = "hunk-3", file = "file.lua", diff = "diff3" },
      },
    }

    before_each(function()
      store.add_suggestion(test_suggestion)
    end)

    it("starts at first hunk", function()
      assert.equals(1, store.get_current_hunk_index())
      assert.equals("hunk-1", store.get_current_hunk().id)
    end)

    it("moves to next hunk", function()
      local moved = store.next_hunk()
      
      assert.is_true(moved)
      assert.equals(2, store.get_current_hunk_index())
      assert.equals("hunk-2", store.get_current_hunk().id)
    end)

    it("returns false at end of hunks", function()
      store.set_current_hunk_index(3)
      
      local moved = store.next_hunk()
      
      assert.is_false(moved)
      assert.equals(3, store.get_current_hunk_index())
    end)

    it("moves to previous hunk", function()
      store.set_current_hunk_index(2)
      
      local moved = store.prev_hunk()
      
      assert.is_true(moved)
      assert.equals(1, store.get_current_hunk_index())
    end)

    it("returns false at start of hunks", function()
      local moved = store.prev_hunk()
      
      assert.is_false(moved)
      assert.equals(1, store.get_current_hunk_index())
    end)

    it("can set hunk index directly", function()
      store.set_current_hunk_index(3)
      
      assert.equals(3, store.get_current_hunk_index())
      assert.equals("hunk-3", store.get_current_hunk().id)
    end)

    it("ignores invalid hunk index", function()
      store.set_current_hunk_index(10)
      
      assert.equals(1, store.get_current_hunk_index())
    end)
  end)

  describe("set_hunk_state", function()
    local test_suggestion = {
      id = "test-1",
      jjChangeId = "abc123",
      description = "Test",
      files = { "file.lua" },
      hunks = {
        { id = "hunk-1", file = "file.lua", diff = "diff1" },
        { id = "hunk-2", file = "file.lua", diff = "diff2" },
      },
    }

    before_each(function()
      store.add_suggestion(test_suggestion)
    end)

    it("updates hunk state", function()
      store.set_hunk_state("hunk-1", "accepted")
      
      local state = store.get_hunk_state("hunk-1")
      assert.equals("accepted", state.status)
    end)

    it("removes hunk from suggestion when reviewed", function()
      store.set_hunk_state("hunk-1", "accepted")
      
      local suggestion = store.get_suggestion("test-1")
      assert.equals(1, #suggestion.hunks)
      assert.equals("hunk-2", suggestion.hunks[1].id)
    end)

    it("removes suggestion when all hunks reviewed", function()
      store.set_hunk_state("hunk-1", "accepted")
      store.set_hunk_state("hunk-2", "rejected")
      
      assert.is_nil(store.get_suggestion("test-1"))
      assert.equals(0, #store.get_suggestions())
    end)

    it("emits on_hunk_applied event", function()
      local emitted_id = nil
      local emitted_status = nil
      
      store.on("on_hunk_applied", function(id, status)
        emitted_id = id
        emitted_status = status
      end)
      
      store.set_hunk_state("hunk-1", "modified")
      
      assert.equals("hunk-1", emitted_id)
      assert.equals("modified", emitted_status)
    end)

    it("stores modified content", function()
      local modified = { "new", "content" }
      store.set_hunk_state("hunk-1", "modified", modified)
      
      local state = store.get_hunk_state("hunk-1")
      assert.same(modified, state.modifiedContent)
    end)
  end)

  describe("get_pending_count", function()
    local test_suggestion = {
      id = "test-1",
      jjChangeId = "abc123",
      description = "Test",
      files = { "file.lua" },
      hunks = {
        { id = "hunk-1", file = "file.lua", diff = "diff1" },
        { id = "hunk-2", file = "file.lua", diff = "diff2" },
        { id = "hunk-3", file = "file.lua", diff = "diff3" },
      },
    }

    it("returns total hunks when all pending", function()
      store.add_suggestion(test_suggestion)
      
      assert.equals(3, store.get_pending_count())
    end)

    it("decreases as hunks are reviewed", function()
      store.add_suggestion(test_suggestion)
      
      store.set_hunk_state("hunk-1", "accepted")
      assert.equals(2, store.get_pending_count())
      
      store.set_hunk_state("hunk-2", "rejected")
      assert.equals(1, store.get_pending_count())
    end)

    it("returns 0 when no suggestion", function()
      assert.equals(0, store.get_pending_count())
    end)
  end)

  describe("original content cache", function()
    it("caches and retrieves content", function()
      local lines = { "line1", "line2", "line3" }
      
      store.cache_original_content("test/file.lua", lines)
      
      local cached = store.get_original_content("test/file.lua")
      assert.same(lines, cached)
    end)

    it("returns nil for uncached files", function()
      assert.is_nil(store.get_original_content("nonexistent.lua"))
    end)
  end)

  describe("clear", function()
    it("clears all state", function()
      local suggestion = {
        id = "test-1",
        jjChangeId = "abc",
        description = "Test",
        files = { "f.lua" },
        hunks = {{ id = "h1", file = "f.lua", diff = "d" }},
      }
      
      store.add_suggestion(suggestion)
      store.cache_original_content("f.lua", { "line" })
      
      store.clear()
      
      assert.equals(0, #store.get_suggestions())
      assert.is_nil(store.get_current_suggestion())
      assert.is_nil(store.get_original_content("f.lua"))
    end)
  end)
end)
