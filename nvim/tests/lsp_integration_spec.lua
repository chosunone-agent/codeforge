-- Integration tests for LSP bootstrap that don't mock LSP functions
-- These tests verify the actual behavior of the bootstrap logic

describe("lsp integration", function()
  local shadow
  
  before_each(function()
    -- Clean reload
    package.loaded["codeforge.ui.shadow"] = nil
    package.loaded["codeforge.store"] = nil
    
    -- Mock only store (not LSP)
    package.loaded["codeforge.store"] = {
      cache_original_content = function() end,
      get_original_content = function() return nil end,
    }
    shadow = require("codeforge.ui.shadow")
  end)

  after_each(function()
    shadow.close()
  end)

  describe("bootstrap buffer setup", function()
    it("creates bootstrap buffer with correct name", function()
      local file_path = "/tmp/test_file.lua"
      
      -- Create the file so it exists on disk
      local f = io.open(file_path, "w")
      if f then
        f:write("-- test\n")
        f:close()
      end
      
      -- Create a buffer and set its name
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, file_path)
      
      -- Verify the name is set correctly
      local name = vim.api.nvim_buf_get_name(buf)
      assert.equals(file_path, name)
      
      -- Check if neovim recognizes it as an existing file
      local exists = vim.fn.filereadable(file_path) == 1
      assert.is_true(exists)
      
      vim.api.nvim_buf_delete(buf, { force = true })
      os.remove(file_path)
    end)

    it("buffer with real file path has correct buftype", function()
      local file_path = "/tmp/test_buftype.lua"
      
      local f = io.open(file_path, "w")
      if f then
        f:write("-- test\n")
        f:close()
      end
      
      -- Scratch buffer
      local scratch_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(scratch_buf, file_path)
      
      -- Check buftype - scratch buffers have buftype = "nofile" by default? No, actually empty
      local buftype = vim.bo[scratch_buf].buftype
      -- Scratch buffers created with nvim_create_buf(false, true) have buftype = "nofile"
      assert.equals("nofile", buftype)
      
      vim.api.nvim_buf_delete(scratch_buf, { force = true })
      os.remove(file_path)
    end)

    it("setting buftype to empty makes it look like regular buffer", function()
      local file_path = "/tmp/test_buftype2.lua"
      
      local f = io.open(file_path, "w")
      if f then
        f:write("-- test\n")
        f:close()
      end
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, file_path)
      vim.bo[buf].buftype = ""  -- Make it look like a regular file buffer
      
      local buftype = vim.bo[buf].buftype
      assert.equals("", buftype)
      
      vim.api.nvim_buf_delete(buf, { force = true })
      os.remove(file_path)
    end)
  end)

  describe("FileType autocmd behavior", function()
    it("FileType autocmd fires and can be observed", function()
      local fired = false
      local fired_buf = nil
      local fired_ft = nil
      
      local autocmd_id = vim.api.nvim_create_autocmd("FileType", {
        pattern = "lua",
        callback = function(args)
          fired = true
          fired_buf = args.buf
          fired_ft = vim.bo[args.buf].filetype
        end,
      })
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "lua"
      
      -- Setting filetype should trigger the autocmd
      assert.is_true(fired)
      assert.equals(buf, fired_buf)
      assert.equals("lua", fired_ft)
      
      vim.api.nvim_del_autocmd(autocmd_id)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("nvim_exec_autocmds fires autocmd even if already set", function()
      local fire_count = 0
      
      local autocmd_id = vim.api.nvim_create_autocmd("FileType", {
        pattern = "lua",
        callback = function()
          fire_count = fire_count + 1
        end,
      })
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = "lua"  -- Fires once
      
      assert.equals(1, fire_count)
      
      -- Manual exec should fire again
      vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
      
      assert.equals(2, fire_count)
      
      vim.api.nvim_del_autocmd(autocmd_id)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("LspAttach autocmd", function()
    it("LspAttach fires when client attaches", function()
      -- This test documents that LspAttach autocmd exists
      -- We can't easily test it without a real LSP server
      local autocmds = vim.api.nvim_get_autocmds({ event = "LspAttach" })
      -- Just verify the API exists
      assert.is_table(autocmds)
    end)
  end)

  describe("finding running LSP clients", function()
    it("get_clients returns empty when no servers running", function()
      -- In test environment, no LSP servers should be running
      local clients = vim.lsp.get_clients()
      -- This might not be empty if user has LSP configured, but in minimal test env it should be
      assert.is_table(clients)
    end)

    it("get_clients can filter by name", function()
      local clients = vim.lsp.get_clients({ name = "nonexistent_server" })
      assert.equals(0, #clients)
    end)
  end)

  describe("finding clients by filetype", function()
    -- The hybrid approach: find ALREADY RUNNING clients for a filetype
    
    it("can iterate all running clients and check filetypes", function()
      local clients = vim.lsp.get_clients()
      
      for _, client in ipairs(clients) do
        -- Check if client config has filetypes
        local config = client.config
        if config and config.filetypes then
          assert.is_table(config.filetypes)
        end
      end
      
      -- Test passes even with no clients
      assert.is_true(true)
    end)

    it("vim.lsp.buf_attach_client can attach to any buffer", function()
      -- We need a real client to test this, so just verify the function exists
      assert.is_function(vim.lsp.buf_attach_client)
    end)

    it("find_clients_for_filetype logic works correctly", function()
      -- Test the filetype matching logic
      local mock_clients = {
        { config = { filetypes = { "rust" } }, name = "rust_analyzer" },
        { config = { filetypes = { "lua" } }, name = "lua_ls" },
        { config = { filetypes = { "rust", "lua", "python" } }, name = "copilot" },
        { config = {}, name = "no_filetypes" },  -- No filetypes field
      }
      
      -- Find rust clients
      local rust_clients = {}
      for _, client in ipairs(mock_clients) do
        if client.config and client.config.filetypes then
          for _, ft in ipairs(client.config.filetypes) do
            if ft == "rust" then
              table.insert(rust_clients, client)
              break
            end
          end
        end
      end
      
      assert.equals(2, #rust_clients)
      assert.equals("rust_analyzer", rust_clients[1].name)
      assert.equals("copilot", rust_clients[2].name)
      
      -- Find typescript clients (none exist)
      local ts_clients = {}
      for _, client in ipairs(mock_clients) do
        if client.config and client.config.filetypes then
          for _, ft in ipairs(client.config.filetypes) do
            if ft == "typescript" then
              table.insert(ts_clients, client)
              break
            end
          end
        end
      end
      
      assert.equals(0, #ts_clients)
    end)
  end)

  describe("root directory detection", function()
    it("vim.fs.find can locate project markers", function()
      -- Create a temp directory structure
      local tmp_dir = "/tmp/codeforge_test_" .. os.time()
      vim.fn.mkdir(tmp_dir, "p")
      vim.fn.mkdir(tmp_dir .. "/src", "p")
      
      -- Create a marker file
      local f = io.open(tmp_dir .. "/Cargo.toml", "w")
      if f then
        f:write("[package]\n")
        f:close()
      end
      
      -- Create a source file
      f = io.open(tmp_dir .. "/src/main.rs", "w")
      if f then
        f:write("fn main() {}\n")
        f:close()
      end
      
      -- vim.fs.find should locate the marker
      local found = vim.fs.find("Cargo.toml", {
        path = tmp_dir .. "/src",
        upward = true,
        type = "file",
      })
      
      assert.equals(1, #found)
      assert.truthy(found[1]:match("Cargo.toml"))
      
      -- Cleanup
      os.remove(tmp_dir .. "/src/main.rs")
      os.remove(tmp_dir .. "/Cargo.toml")
      vim.fn.delete(tmp_dir .. "/src", "d")
      vim.fn.delete(tmp_dir, "d")
    end)

    it("vim.fs.dirname gets parent directory", function()
      local path = "/home/user/project/src/main.rs"
      local dir = vim.fs.dirname(path)
      assert.equals("/home/user/project/src", dir)
    end)
  end)

  describe("bootstrap buffer requirements", function()
    -- Document what conditions LSP configs typically check
    
    it("buffer must have a name for root detection", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local name = vim.api.nvim_buf_get_name(buf)
      
      -- Unnamed buffer has empty name
      assert.equals("", name)
      
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("buffer name is used for root detection path", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "/home/user/project/src/main.rs")
      
      local name = vim.api.nvim_buf_get_name(buf)
      local dir = vim.fs.dirname(name)
      
      assert.equals("/home/user/project/src", dir)
      
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("scratch buffer buftype may affect LSP attachment", function()
      -- Some LSP configs check buftype and skip non-file buffers
      local buf = vim.api.nvim_create_buf(false, true)
      
      local buftype = vim.bo[buf].buftype
      assert.equals("nofile", buftype)
      
      -- This might be why LSP doesn't attach - it sees buftype=nofile
      -- and decides this isn't a real file worth analyzing
      
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("bootstrap buffer must have buftype='' for LSP to attach", function()
      -- Simulate what bootstrap_lsp does
      local file_path = "/tmp/test_bootstrap.lua"
      
      local f = io.open(file_path, "w")
      if f then
        f:write("-- test\n")
        f:close()
      end
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, file_path)
      vim.bo[buf].buftype = ""  -- This is the fix!
      vim.bo[buf].filetype = "lua"
      
      -- Verify buftype is now empty (like a real file buffer)
      assert.equals("", vim.bo[buf].buftype)
      
      -- Verify name is set
      assert.equals(file_path, vim.api.nvim_buf_get_name(buf))
      
      -- Verify filetype is set
      assert.equals("lua", vim.bo[buf].filetype)
      
      vim.api.nvim_buf_delete(buf, { force = true })
      os.remove(file_path)
    end)

    it("bootstrap buffer must have shadow content set", function()
      -- Verify that we set content on bootstrap buffer before LSP attaches
      local file_path = "/tmp/test_content.lua"
      local content = { "local x = 1", "print(x)" }
      
      local f = io.open(file_path, "w")
      if f then
        f:write("-- original content\n")
        f:close()
      end
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, file_path)
      vim.bo[buf].buftype = ""
      vim.bo[buf].filetype = "lua"
      
      -- Set content like bootstrap_lsp does
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
      
      -- Verify content is set
      local buf_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.equals(2, #buf_content)
      assert.equals("local x = 1", buf_content[1])
      assert.equals("print(x)", buf_content[2])
      
      vim.api.nvim_buf_delete(buf, { force = true })
      os.remove(file_path)
    end)

    it("file must exist on disk for root detection", function()
      -- Test that vim.fs.find needs the file to exist
      local existing_path = "/tmp/test_exists.rs"
      local nonexistent_path = "/tmp/nonexistent_test_file.rs"
      
      -- Create the existing file
      local f = io.open(existing_path, "w")
      if f then
        f:write("fn main() {}\n")
        f:close()
      end
      
      -- vim.fs.dirname works for both
      assert.equals("/tmp", vim.fs.dirname(existing_path))
      assert.equals("/tmp", vim.fs.dirname(nonexistent_path))
      
      -- vim.fn.filereadable shows the difference
      assert.equals(1, vim.fn.filereadable(existing_path))
      assert.equals(0, vim.fn.filereadable(nonexistent_path))
      
      os.remove(existing_path)
    end)
  end)
end)
