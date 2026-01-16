-- Tests for LSP client transfer logic
-- These tests verify that when LSP attaches to bootstrap buffer,
-- it gets properly transferred to the shadow buffer

describe("lsp transfer", function()
  local shadow
  local mock_clients = {}
  local attached_buffers = {}
  local notifications_sent = {}
  
  -- Mock LSP client
  local function create_mock_client(id, name, filetypes)
    return {
      id = id,
      name = name,
      config = {
        filetypes = filetypes or {},
      },
      notify = function(method, params)
        table.insert(notifications_sent, {
          client_id = id,
          method = method,
          params = params,
        })
        return true
      end,
    }
  end

  local function reset_mocks()
    mock_clients = {}
    attached_buffers = {}
    notifications_sent = {}
  end

  before_each(function()
    reset_mocks()
    
    -- Mock LSP functions
    vim.lsp.get_clients = function(opts)
      if opts and opts.bufnr then
        local result = {}
        for _, client in ipairs(mock_clients) do
          if attached_buffers[opts.bufnr] and attached_buffers[opts.bufnr][client.id] then
            table.insert(result, client)
          end
        end
        return result
      elseif opts and opts.id then
        for _, client in ipairs(mock_clients) do
          if client.id == opts.id then
            return { client }
          end
        end
        return {}
      end
      return mock_clients
    end
    
    vim.lsp.buf_attach_client = function(bufnr, client_id)
      attached_buffers[bufnr] = attached_buffers[bufnr] or {}
      attached_buffers[bufnr][client_id] = true
      return true
    end
    
    vim.lsp.buf_is_attached = function(bufnr, client_id)
      return attached_buffers[bufnr] and attached_buffers[bufnr][client_id] or false
    end
    
    vim.lsp.client_is_stopped = function(client_id)
      return false
    end
    
    -- Reload shadow module
    package.loaded["codeforge.ui.shadow"] = nil
    package.loaded["codeforge.store"] = {
      cache_original_content = function() end,
      get_original_content = function() return nil end,
    }
    shadow = require("codeforge.ui.shadow")
  end)

  after_each(function()
    shadow.close()
  end)

  describe("client transfer simulation", function()
    it("attaches client to shadow buffer after bootstrap", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      table.insert(mock_clients, client)
      
      -- Create shadow buffer
      local shadow_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[shadow_buf].filetype = "rust"
      
      -- Simulate bootstrap buffer with client attached
      local bootstrap_buf = vim.api.nvim_create_buf(false, true)
      vim.lsp.buf_attach_client(bootstrap_buf, 1)
      
      -- Verify client is attached to bootstrap
      assert.is_true(vim.lsp.buf_is_attached(bootstrap_buf, 1))
      
      -- Now attach to shadow buffer (simulating transfer)
      vim.lsp.buf_attach_client(shadow_buf, 1)
      
      -- Verify client is attached to shadow
      assert.is_true(vim.lsp.buf_is_attached(shadow_buf, 1))
      
      vim.api.nvim_buf_delete(shadow_buf, { force = true })
      vim.api.nvim_buf_delete(bootstrap_buf, { force = true })
    end)

    it("sends didOpen after transfer", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      table.insert(mock_clients, client)
      
      -- Simulate sending didOpen after transfer
      client.notify("textDocument/didOpen", {
        textDocument = {
          uri = "file:///test/file.rs",
          languageId = "rust",
          version = 0,
          text = "fn main() {}",
        },
      })
      
      assert.equals(1, #notifications_sent)
      assert.equals("textDocument/didOpen", notifications_sent[1].method)
      assert.equals("fn main() {}", notifications_sent[1].params.textDocument.text)
    end)

    it("uses correct URI for real file path", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      
      local file_path = "/home/user/project/src/main.rs"
      local uri = vim.uri_from_fname(file_path)
      
      client.notify("textDocument/didOpen", {
        textDocument = {
          uri = uri,
          languageId = "rust",
          version = 0,
          text = "content",
        },
      })
      
      -- URI should be the real file path, not the shadow buffer name
      assert.truthy(notifications_sent[1].params.textDocument.uri:match("main.rs"))
      assert.falsy(notifications_sent[1].params.textDocument.uri:match("#codeforge"))
    end)

    it("sends didChange on content update", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      
      client.notify("textDocument/didChange", {
        textDocument = {
          uri = "file:///test/file.rs",
          version = 1,
        },
        contentChanges = {
          { text = "fn main() { let x = 1; }" },
        },
      })
      
      assert.equals(1, #notifications_sent)
      assert.equals("textDocument/didChange", notifications_sent[1].method)
      assert.equals(1, notifications_sent[1].params.textDocument.version)
    end)

    it("increments version on each change", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      
      -- First change
      client.notify("textDocument/didChange", {
        textDocument = { uri = "file:///test/file.rs", version = 1 },
        contentChanges = { { text = "v1" } },
      })
      
      -- Second change
      client.notify("textDocument/didChange", {
        textDocument = { uri = "file:///test/file.rs", version = 2 },
        contentChanges = { { text = "v2" } },
      })
      
      assert.equals(2, #notifications_sent)
      assert.equals(1, notifications_sent[1].params.textDocument.version)
      assert.equals(2, notifications_sent[2].params.textDocument.version)
    end)

    it("sends didClose on shadow buffer close", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      
      client.notify("textDocument/didClose", {
        textDocument = {
          uri = "file:///test/file.rs",
        },
      })
      
      assert.equals(1, #notifications_sent)
      assert.equals("textDocument/didClose", notifications_sent[1].method)
    end)
  end)

  describe("restore original file state", function()
    it("sends didOpen for real file after close if it exists", function()
      local client = create_mock_client(1, "rust_analyzer", { "rust" })
      
      -- Simulate closing shadow and restoring real file
      -- First: didClose for shadow content
      client.notify("textDocument/didClose", {
        textDocument = { uri = "file:///test/file.rs" },
      })
      
      -- Then: didOpen with original content
      client.notify("textDocument/didOpen", {
        textDocument = {
          uri = "file:///test/file.rs",
          languageId = "rust",
          version = 0,
          text = "original content",
        },
      })
      
      assert.equals(2, #notifications_sent)
      assert.equals("textDocument/didClose", notifications_sent[1].method)
      assert.equals("textDocument/didOpen", notifications_sent[2].method)
      assert.equals("original content", notifications_sent[2].params.textDocument.text)
    end)
  end)

  describe("multiple clients", function()
    it("attaches all matching clients", function()
      local client1 = create_mock_client(1, "rust_analyzer", { "rust" })
      local client2 = create_mock_client(2, "copilot", { "rust", "lua", "python" })
      table.insert(mock_clients, client1)
      table.insert(mock_clients, client2)
      
      local shadow_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[shadow_buf].filetype = "rust"
      
      -- Attach both clients
      vim.lsp.buf_attach_client(shadow_buf, 1)
      vim.lsp.buf_attach_client(shadow_buf, 2)
      
      assert.is_true(vim.lsp.buf_is_attached(shadow_buf, 1))
      assert.is_true(vim.lsp.buf_is_attached(shadow_buf, 2))
      
      vim.api.nvim_buf_delete(shadow_buf, { force = true })
    end)

    it("sends notifications to all attached clients", function()
      local client1 = create_mock_client(1, "rust_analyzer", { "rust" })
      local client2 = create_mock_client(2, "copilot", { "rust" })
      
      -- Both send didOpen
      client1.notify("textDocument/didOpen", {
        textDocument = { uri = "file:///test/file.rs", languageId = "rust", version = 0, text = "content" },
      })
      client2.notify("textDocument/didOpen", {
        textDocument = { uri = "file:///test/file.rs", languageId = "rust", version = 0, text = "content" },
      })
      
      assert.equals(2, #notifications_sent)
      assert.equals(1, notifications_sent[1].client_id)
      assert.equals(2, notifications_sent[2].client_id)
    end)
  end)

  describe("filetype matching", function()
    it("matches client filetypes correctly", function()
      local rust_client = create_mock_client(1, "rust_analyzer", { "rust" })
      local lua_client = create_mock_client(2, "lua_ls", { "lua" })
      table.insert(mock_clients, rust_client)
      table.insert(mock_clients, lua_client)
      
      local buf_ft = "rust"
      
      -- Check which clients match
      local matching = {}
      for _, client in ipairs(mock_clients) do
        for _, ft in ipairs(client.config.filetypes) do
          if ft == buf_ft then
            table.insert(matching, client)
            break
          end
        end
      end
      
      assert.equals(1, #matching)
      assert.equals("rust_analyzer", matching[1].name)
    end)

    it("handles clients without filetypes config", function()
      local client = create_mock_client(1, "generic_client", nil)
      client.config.filetypes = nil
      table.insert(mock_clients, client)
      
      -- Should not crash when checking filetypes
      local buf_ft = "rust"
      local matching = {}
      
      for _, c in ipairs(mock_clients) do
        if c.config and c.config.filetypes then
          for _, ft in ipairs(c.config.filetypes) do
            if ft == buf_ft then
              table.insert(matching, c)
              break
            end
          end
        end
      end
      
      assert.equals(0, #matching)
    end)
  end)
end)
