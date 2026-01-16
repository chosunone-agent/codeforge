-- WebSocket client for neovim using vim.uv/vim.loop (libuv)
-- Adapted from instant.nvim (MIT License)

local base64 = require("codeforge.websocket.base64")
local bit = bit or bit32 or require("bit")

-- Handle both vim.uv (neovim 0.10+) and vim.loop (older)
local uv = vim.uv or vim.loop

local M = {}

---Generate a random WebSocket key
---@return number[]
local function generate_websocket_key()
  local key = {}
  math.randomseed(os.time())
  for _ = 1, 16 do
    table.insert(key, math.random(0, 255))
  end
  return key
end

---Case-insensitive pattern
---@param s string
---@return string
local function nocase(s)
  return string.gsub(s, "%a", function(c)
    if string.match(c, "[a-zA-Z]") then
      return string.format("[%s%s]", string.lower(c), string.upper(c))
    else
      return c
    end
  end)
end

---Mask text for WebSocket frame
---@param str string
---@param mask number[]
---@return number[]
local function mask_text(str, mask)
  local masked = {}
  for i = 0, #str - 1 do
    local j = bit.band(i, 0x3)
    local trans = bit.bxor(string.byte(string.sub(str, i + 1, i + 1)), mask[j + 1])
    table.insert(masked, trans)
  end
  return masked
end

---Convert byte array to string
---@param tab number[]
---@return string
local function bytes_to_string(tab)
  local s = ""
  for _, el in ipairs(tab) do
    s = s .. string.char(el)
  end
  return s
end

---@class WebSocketCallbacks
---@field on_connect? fun()
---@field on_message? fun(data: string)
---@field on_disconnect? fun()
---@field on_error? fun(err: string)

---@class WebSocketClient
---@field connect fun(self: WebSocketClient, callbacks: WebSocketCallbacks)
---@field send fun(self: WebSocketClient, message: string)
---@field send_json fun(self: WebSocketClient, data: table)
---@field disconnect fun(self: WebSocketClient)
---@field is_active fun(self: WebSocketClient): boolean

---Create a new WebSocket client
---@param opts { host: string, port: number, path?: string }
---@return WebSocketClient|nil
function M.create(opts)
  local host = opts.host or "127.0.0.1"
  local port = opts.port or 80
  local path = opts.path or "/"

  local iptable = uv.getaddrinfo(host)
  if not iptable or #iptable == 0 then
    return nil
  end
  local ipentry = iptable[1]

  local client = uv.new_tcp()
  if not client then
    return nil
  end
  local chunk_buffer = ""
  local upgraded = false
  local http_chunk = ""
  local callbacks = {}
  local max_before_frag = 8192

  local ws = {}

  ---Connect to the WebSocket server
  ---@param cbs WebSocketCallbacks
  function ws:connect(cbs)
    callbacks = cbs or {}

    local ret, err = client:connect(ipentry.addr, port, vim.schedule_wrap(function(connect_err)
      if connect_err then
        if callbacks.on_error then
          callbacks.on_error("Connection error: " .. connect_err)
        end
        return
      end

      -- Coroutine for parsing WebSocket frames
      local function getdata(amount)
        while string.len(chunk_buffer) < amount do
          coroutine.yield()
        end
        local retrieved = string.sub(chunk_buffer, 1, amount)
        chunk_buffer = string.sub(chunk_buffer, amount + 1)
        return retrieved
      end

      local wsread_co = coroutine.create(function()
        while true do
          local wsdata = ""

          -- Read frame header
          local rec = getdata(2)
          local b1 = string.byte(string.sub(rec, 1, 1))
          local b2 = string.byte(string.sub(rec, 2, 2))
          local opcode = bit.band(b1, 0xF)
          local fin = bit.rshift(b1, 7)

          -- Read payload length
          local paylen = bit.band(b2, 0x7F)
          if paylen == 126 then
            rec = getdata(2)
            local b3 = string.byte(string.sub(rec, 1, 1))
            local b4 = string.byte(string.sub(rec, 2, 2))
            paylen = bit.lshift(b3, 8) + b4
          elseif paylen == 127 then
            paylen = 0
            rec = getdata(8)
            for i = 1, 8 do
              paylen = bit.lshift(paylen, 8)
              paylen = paylen + string.byte(string.sub(rec, i, i))
            end
          end

          -- Read payload
          local data = getdata(paylen)
          wsdata = data

          -- Handle fragmented messages
          while fin == 0 do
            rec = getdata(2)
            b1 = string.byte(string.sub(rec, 1, 1))
            b2 = string.byte(string.sub(rec, 2, 2))
            fin = bit.rshift(b1, 7)

            paylen = bit.band(b2, 0x7F)
            if paylen == 126 then
              rec = getdata(2)
              local b3 = string.byte(string.sub(rec, 1, 1))
              local b4 = string.byte(string.sub(rec, 2, 2))
              paylen = bit.lshift(b3, 8) + b4
            elseif paylen == 127 then
              paylen = 0
              rec = getdata(8)
              for i = 1, 8 do
                paylen = bit.lshift(paylen, 8)
                paylen = paylen + string.byte(string.sub(rec, i, i))
              end
            end

            data = getdata(paylen)
            wsdata = wsdata .. data
          end

          -- Handle different opcodes
          if opcode == 0x1 then -- TEXT
            if callbacks.on_message then
              callbacks.on_message(wsdata)
            end
          elseif opcode == 0x9 then -- PING
            -- Send PONG
            local mask = {}
            for _ = 1, 4 do
              table.insert(mask, math.random(0, 255))
            end
            local frame = { 0x8A, 0x80 }
            for i = 1, 4 do
              table.insert(frame, mask[i])
            end
            client:write(bytes_to_string(frame))
          elseif opcode == 0x8 then -- CLOSE
            if callbacks.on_disconnect then
              callbacks.on_disconnect()
            end
            break
          end
        end
      end)

      -- Start reading data
      local read_ok, read_err2 = client:read_start(vim.schedule_wrap(function(read_err, chunk)
        if read_err then
          if callbacks.on_error then
            callbacks.on_error("Read error: " .. read_err)
          end
          return
        end

        if chunk then
          if not upgraded then
            -- Still in HTTP handshake phase
            http_chunk = http_chunk .. chunk
            if string.find(http_chunk, "\r\n\r\n", 1, true) then
              if string.find(http_chunk, "HTTP/1.1 101", 1, true) then
                if string.find(http_chunk:lower(), "sec%-websocket%-accept") then
                  upgraded = true
                  -- Check if there's data after the headers
                  local header_end = http_chunk:find("\r\n\r\n")
                  if header_end then
                    local remaining = http_chunk:sub(header_end + 4)
                    if #remaining > 0 then
                      chunk_buffer = remaining
                    end
                  end
                  http_chunk = ""
                  if callbacks.on_connect then
                    callbacks.on_connect()
                  end
                  -- Resume coroutine if we have data
                  if #chunk_buffer > 0 then
                    coroutine.resume(wsread_co)
                  end
                else
                  if callbacks.on_error then
                    callbacks.on_error("WebSocket upgrade failed")
                  end
                end
              end
            end
          else
            -- WebSocket frame data
            chunk_buffer = chunk_buffer .. chunk
            coroutine.resume(wsread_co)
          end
        else
          -- Connection closed
          if callbacks.on_disconnect then
            callbacks.on_disconnect()
          end
        end
      end))

      -- Send WebSocket handshake
      local websocket_key = base64.encode(generate_websocket_key())
      client:write("GET " .. path .. " HTTP/1.1\r\n")
      client:write("Host: " .. host .. ":" .. port .. "\r\n")
      client:write("Upgrade: websocket\r\n")
      client:write("Connection: Upgrade\r\n")
      client:write("Sec-WebSocket-Key: " .. websocket_key .. "\r\n")
      client:write("Sec-WebSocket-Version: 13\r\n")
      client:write("\r\n")
    end))

    if not ret then
      if callbacks.on_error then
        callbacks.on_error("Failed to initiate connection: " .. (err or "unknown error"))
      end
    end
  end

  ---Send a text message
  ---@param str string
  function ws:send(str)
    if not client or not client:is_active() then
      return
    end

    local mask = {}
    for _ = 1, 4 do
      table.insert(mask, math.random(0, 255))
    end

    local masked = mask_text(str, mask)
    local remain = #masked
    local sent = 0

    while remain > 0 do
      local send_amount = math.min(max_before_frag, remain)
      remain = remain - send_amount

      local fin = remain == 0 and 0x80 or 0
      local op = sent == 0 and 1 or 0

      local frame = { fin + op, 0x80 }

      if send_amount <= 125 then
        frame[2] = frame[2] + send_amount
      elseif send_amount < math.pow(2, 16) then
        frame[2] = frame[2] + 126
        local b1 = bit.rshift(send_amount, 8)
        local b2 = bit.band(send_amount, 0xFF)
        table.insert(frame, b1)
        table.insert(frame, b2)
      else
        frame[2] = frame[2] + 127
        for i = 0, 7 do
          local b = bit.band(bit.rshift(send_amount, (7 - i) * 8), 0xFF)
          table.insert(frame, b)
        end
      end

      for i = 1, 4 do
        table.insert(frame, mask[i])
      end

      for i = sent + 1, sent + send_amount do
        table.insert(frame, masked[i])
      end

      client:write(bytes_to_string(frame))
      sent = sent + send_amount
    end
  end

  ---Send a JSON message
  ---@param data table
  function ws:send_json(data)
    self:send(vim.json.encode(data))
  end

  ---Disconnect from the server
  function ws:disconnect()
    if not client then
      return
    end

    -- Send close frame
    local mask = {}
    for _ = 1, 4 do
      table.insert(mask, math.random(0, 255))
    end
    local frame = { 0x88, 0x80 }
    for i = 1, 4 do
      table.insert(frame, mask[i])
    end
    client:write(bytes_to_string(frame))

    client:shutdown()
    client:close()
    client = nil

    if callbacks.on_disconnect then
      callbacks.on_disconnect()
    end
  end

  ---Check if connection is active
  ---@return boolean
  function ws:is_active()
    return client ~= nil and client:is_active()
  end

  return setmetatable({}, { __index = ws })
end

return M
