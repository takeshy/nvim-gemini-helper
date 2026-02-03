-- MCP App Bridge for Neovim
-- Opens MCP App UI in browser with WebSocket bridge for bidirectional communication
--
-- Architecture:
-- Neovim <-> WebSocket Server <-> Bridge HTML <-> iframe (MCP App)
--                                     |              |
--                                  postMessage <----+

local M = {}

local uv = vim.loop
local bit = require("bit")

---@class McpAppBridge
---@field server userdata TCP server
---@field port number Server port
---@field clients table Connected WebSocket clients
---@field on_message function Callback for messages from MCP App
---@field origin string Allowed origin for the MCP App
local McpAppBridge = {}
McpAppBridge.__index = McpAppBridge

-- WebSocket constants
local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local WS_OPCODE_TEXT = 0x1
local WS_OPCODE_CLOSE = 0x8
local WS_OPCODE_PING = 0x9
local WS_OPCODE_PONG = 0xA

---Calculate SHA1 hash (simplified, uses openssl)
---@param data string
---@return string base64 encoded SHA1
local function sha1_base64(data)
  local cmd = "echo -n '" .. data:gsub("'", "'\\''") .. "' | openssl sha1 -binary | base64"
  local handle = io.popen(cmd)
  if not handle then
    return ""
  end
  local result = handle:read("*a")
  handle:close()
  return result:gsub("%s+", "")
end

---Parse HTTP request headers
---@param data string
---@return table headers
local function parse_http_headers(data)
  local headers = {}
  local first_line = true

  for line in data:gmatch("[^\r\n]+") do
    if first_line then
      headers._method, headers._path = line:match("^(%S+)%s+(%S+)")
      first_line = false
    else
      local key, value = line:match("^([^:]+):%s*(.+)$")
      if key then
        headers[key:lower()] = value
      end
    end
  end

  return headers
end

---Build WebSocket accept key
---@param client_key string
---@return string
local function build_accept_key(client_key)
  return sha1_base64(client_key .. WS_GUID)
end

---Encode WebSocket frame
---@param data string
---@param opcode number
---@return string
local function encode_ws_frame(data, opcode)
  opcode = opcode or WS_OPCODE_TEXT
  local len = #data
  local frame = {}

  -- FIN + opcode
  table.insert(frame, string.char(0x80 + opcode))

  -- Length (no mask for server->client)
  if len <= 125 then
    table.insert(frame, string.char(len))
  elseif len <= 65535 then
    table.insert(frame, string.char(126))
    table.insert(frame, string.char(bit.rshift(len, 8)))
    table.insert(frame, string.char(bit.band(len, 0xFF)))
  else
    table.insert(frame, string.char(127))
    for i = 7, 0, -1 do
      table.insert(frame, string.char(bit.band(bit.rshift(len, i * 8), 0xFF)))
    end
  end

  table.insert(frame, data)
  return table.concat(frame)
end

---Decode WebSocket frame
---@param data string
---@return string|nil payload
---@return number|nil opcode
---@return number bytes_consumed
local function decode_ws_frame(data)
  if #data < 2 then
    return nil, nil, 0
  end

  local b1 = string.byte(data, 1)
  local b2 = string.byte(data, 2)

  local opcode = bit.band(b1, 0x0F)
  local masked = bit.band(b2, 0x80) ~= 0
  local payload_len = bit.band(b2, 0x7F)

  local header_len = 2
  if payload_len == 126 then
    if #data < 4 then
      return nil, nil, 0
    end
    payload_len = bit.lshift(string.byte(data, 3), 8) + string.byte(data, 4)
    header_len = 4
  elseif payload_len == 127 then
    if #data < 10 then
      return nil, nil, 0
    end
    payload_len = 0
    for i = 3, 10 do
      payload_len = bit.lshift(payload_len, 8) + string.byte(data, i)
    end
    header_len = 10
  end

  if masked then
    header_len = header_len + 4
  end

  local total_len = header_len + payload_len
  if #data < total_len then
    return nil, nil, 0
  end

  local payload
  if masked then
    local mask_start = header_len - 3
    local mask = { string.byte(data, mask_start, mask_start + 3) }
    local payload_bytes = {}
    for i = 1, payload_len do
      local byte = string.byte(data, header_len + i)
      local mask_byte = mask[((i - 1) % 4) + 1]
      table.insert(payload_bytes, string.char(bit.bxor(byte, mask_byte)))
    end
    payload = table.concat(payload_bytes)
  else
    payload = data:sub(header_len + 1, total_len)
  end

  return payload, opcode, total_len
end

---Create a new MCP App Bridge
---@param opts table|nil Options { on_message, origin }
---@return McpAppBridge|nil
---@return string|nil error
function M.new(opts)
  opts = opts or {}

  local self = setmetatable({}, McpAppBridge)
  self.clients = {}
  self.on_message = opts.on_message or function() end
  self.origin = opts.origin or "*"

  -- Create TCP server
  local server = uv.new_tcp()
  if not server then
    return nil, "Failed to create TCP server"
  end

  -- Try to bind to a random port (port 0 = let OS choose)
  -- Note: uv.tcp:bind() returns 0 on success, or fail (nil), err_msg on error
  -- In Lua, 0 is truthy, so we must check explicitly
  local bind_result, bind_err = server:bind("127.0.0.1", 0)
  if bind_result == nil or (type(bind_result) == "number" and bind_result ~= 0) then
    server:close()
    return nil, "Failed to bind: " .. tostring(bind_err or bind_result)
  end

  -- Get the assigned port
  local addr = server:getsockname()
  self.port = addr.port
  self.server = server

  -- Start listening
  server:listen(128, function(listen_err)
    if listen_err then
      vim.schedule(function()
        vim.notify("MCP App Bridge listen error: " .. listen_err, vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    server:accept(client)

    local buffer = ""
    local ws_upgraded = false

    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        return
      end

      if not data then
        -- Client disconnected
        self.clients[client] = nil
        client:close()
        return
      end

      buffer = buffer .. data

      if not ws_upgraded then
        -- Check for complete HTTP headers
        local headers_end = buffer:find("\r\n\r\n")
        if headers_end then
          local headers = parse_http_headers(buffer:sub(1, headers_end))
          buffer = buffer:sub(headers_end + 4)

          -- Check for WebSocket upgrade
          if headers["upgrade"] and headers["upgrade"]:lower() == "websocket" then
            local client_key = headers["sec-websocket-key"]
            if client_key then
              local accept_key = build_accept_key(client_key)
              local response = table.concat({
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Accept: " .. accept_key,
                "",
                "",
              }, "\r\n")

              client:write(response)
              ws_upgraded = true
              self.clients[client] = true
            end
          else
            -- Regular HTTP request - reject
            local response = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
            client:write(response, function()
              client:close()
            end)
          end
        end
      else
        -- WebSocket frame handling
        while #buffer > 0 do
          local payload, opcode, consumed = decode_ws_frame(buffer)
          if consumed == 0 then
            break
          end

          buffer = buffer:sub(consumed + 1)

          if opcode == WS_OPCODE_TEXT then
            -- Text message received
            vim.schedule(function()
              local ok, msg = pcall(vim.json.decode, payload)
              if ok then
                self.on_message(msg, client)
              else
                vim.notify("[WS] Failed to decode JSON: " .. tostring(msg), vim.log.levels.ERROR)
              end
            end)
          elseif opcode == WS_OPCODE_PING then
            -- Respond with pong
            client:write(encode_ws_frame(payload, WS_OPCODE_PONG))
          elseif opcode == WS_OPCODE_CLOSE then
            -- Close connection
            client:write(encode_ws_frame("", WS_OPCODE_CLOSE), function()
              self.clients[client] = nil
              client:close()
            end)
          end
        end
      end
    end)
  end)

  return self, nil
end

---Send a message to all connected clients
---@param self McpAppBridge
---@param message table JSON-serializable message
function McpAppBridge:broadcast(message)
  local json_str = vim.json.encode(message)
  local frame = encode_ws_frame(json_str, WS_OPCODE_TEXT)

  for client, _ in pairs(self.clients) do
    client:write(frame)
  end
end

---Send a message to a specific client
---@param self McpAppBridge
---@param client userdata
---@param message table
---@return boolean success
---@return string|nil error
function McpAppBridge:send(client, message)
  local ok, json_str = pcall(vim.json.encode, message)
  if not ok then
    return false, "JSON encode error: " .. tostring(json_str)
  end

  local frame = encode_ws_frame(json_str, WS_OPCODE_TEXT)

  local write_ok, write_err = pcall(function()
    client:write(frame)
  end)

  if not write_ok then
    return false, "Write error: " .. tostring(write_err)
  end

  return true, nil
end

---Close the bridge
---@param self McpAppBridge
function McpAppBridge:close()
  -- Close all WebSocket clients
  for client, _ in pairs(self.clients) do
    pcall(function()
      client:write(encode_ws_frame("", WS_OPCODE_CLOSE), function()
        client:close()
      end)
    end)
  end
  self.clients = {}

  -- Close WebSocket server
  if self.server then
    self.server:close()
    self.server = nil
  end

  -- Close HTTP server
  if self.http_server then
    self.http_server:close()
    self.http_server = nil
  end
end

-- Script to inject into iframe for mcpApps bridge
local IFRAME_BRIDGE_SCRIPT = [[
<script>
(function() {
  // Bridge for MCP App communication with Neovim via parent window
  let requestId = 0;
  const pendingRequests = new Map();

  window.mcpApps = {
    callTool: function(name, args) {
      return new Promise((resolve, reject) => {
        const id = ++requestId;
        pendingRequests.set(id, { resolve, reject });

        window.parent.postMessage({
          type: 'mcp_tool_call',
          id: id,
          name: name,
          args: args || {}
        }, '*');

        // Timeout after 30 seconds
        setTimeout(() => {
          if (pendingRequests.has(id)) {
            pendingRequests.delete(id);
            reject(new Error('Tool call timeout'));
          }
        }, 30000);
      });
    }
  };

  // Listen for responses from parent
  window.addEventListener('message', function(event) {
    console.log('[MCP Bridge iframe] Received message:', event.data);
    const msg = event.data;
    if (msg && msg.type === 'mcp_tool_response' && msg.id) {
      console.log('[MCP Bridge iframe] Tool response for id:', msg.id);
      const pending = pendingRequests.get(msg.id);
      if (pending) {
        console.log('[MCP Bridge iframe] Found pending request, resolving');
        pendingRequests.delete(msg.id);
        if (msg.error) {
          pending.reject(new Error(msg.error));
        } else {
          pending.resolve(msg.result);
        }
      } else {
        console.log('[MCP Bridge iframe] No pending request for id:', msg.id);
      }
    }
  });

  console.log('[MCP Bridge] mcpApps bridge initialized');
})();
</script>
]]

---Inject bridge script into MCP App HTML content
---@param html_content string Original HTML content
---@return string Modified HTML with bridge script injected
local function inject_bridge_script(html_content)
  -- Try to inject after <head> tag
  local head_pos = html_content:find("<head[^>]*>")
  if head_pos then
    local head_end = html_content:find(">", head_pos)
    if head_end then
      return html_content:sub(1, head_end) .. "\n" .. IFRAME_BRIDGE_SCRIPT .. html_content:sub(head_end + 1)
    end
  end

  -- Try to inject after <!DOCTYPE> or at the beginning
  local doctype_end = html_content:find("<!DOCTYPE[^>]*>")
  if doctype_end then
    local pos = html_content:find(">", doctype_end)
    if pos then
      return html_content:sub(1, pos) .. "\n" .. IFRAME_BRIDGE_SCRIPT .. html_content:sub(pos + 1)
    end
  end

  -- Fallback: prepend to content
  return IFRAME_BRIDGE_SCRIPT .. html_content
end

---Generate bridge HTML that embeds the MCP App
---@param ui_resource table { uri, mimeType, text, blob }
---@param ws_port number WebSocket server port
---@param mcp_server_url string MCP server URL for origin
---@return string html
function M.generate_bridge_html(ui_resource, ws_port, mcp_server_url)
  local app_content = ""

  if ui_resource.text then
    -- Inline HTML content
    app_content = ui_resource.text
  elseif ui_resource.blob then
    -- Base64 encoded content
    app_content = vim.base64.decode(ui_resource.blob)
  end

  -- Inject bridge script into app content
  local modified_app_content = inject_bridge_script(app_content)

  -- Extract origin from MCP server URL for postMessage
  local origin = mcp_server_url:match("^(https?://[^/]+)") or "*"

  local html = [[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MCP App - Neovim Bridge</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #1a1a2e;
      color: #eee;
      min-height: 100vh;
    }
    .header {
      background: #16213e;
      padding: 8px 16px;
      display: flex;
      align-items: center;
      gap: 12px;
      border-bottom: 1px solid #0f3460;
    }
    .status {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      background: #e74c3c;
    }
    .status.connected { background: #2ecc71; }
    .status-text { font-size: 12px; color: #888; }
    .container {
      height: calc(100vh - 41px);
      display: flex;
    }
    iframe {
      flex: 1;
      border: none;
      background: white;
    }
    .log {
      width: 300px;
      background: #0f0f23;
      border-left: 1px solid #0f3460;
      padding: 8px;
      font-family: monospace;
      font-size: 11px;
      overflow-y: auto;
      display: none;
    }
    .log.show { display: block; }
    .log-entry { margin-bottom: 4px; padding: 4px; border-radius: 2px; }
    .log-entry.in { background: #1a3a1a; }
    .log-entry.out { background: #3a1a1a; }
    .toggle-log {
      background: none;
      border: 1px solid #0f3460;
      color: #888;
      padding: 4px 8px;
      cursor: pointer;
      font-size: 11px;
      margin-left: auto;
    }
    .toggle-log:hover { border-color: #2ecc71; color: #2ecc71; }
  </style>
</head>
<body>
  <div class="header">
    <div class="status" id="status"></div>
    <span class="status-text" id="status-text">Connecting...</span>
    <button class="toggle-log" onclick="toggleLog()">Toggle Log</button>
  </div>
  <div class="container">
    <iframe id="app-frame"></iframe>
    <div class="log" id="log"></div>
  </div>

  <script>
    const WS_PORT = ]] .. ws_port .. [[;
    const MCP_ORIGIN = ']] .. origin .. [[';

    let ws = null;
    let reconnectTimer = null;
    const statusEl = document.getElementById('status');
    const statusTextEl = document.getElementById('status-text');
    const logEl = document.getElementById('log');
    const iframe = document.getElementById('app-frame');

    function log(direction, data) {
      const entry = document.createElement('div');
      entry.className = 'log-entry ' + direction;
      entry.textContent = (direction === 'in' ? '← ' : '→ ') + JSON.stringify(data).slice(0, 100);
      logEl.appendChild(entry);
      logEl.scrollTop = logEl.scrollHeight;
    }

    function toggleLog() {
      logEl.classList.toggle('show');
    }

    function setStatus(connected) {
      statusEl.className = 'status' + (connected ? ' connected' : '');
      statusTextEl.textContent = connected ? 'Connected to Neovim' : 'Disconnected';
    }

    // Queue for tool calls that arrive before WebSocket is connected
    const pendingToolCalls = [];

    // Listen for messages from iframe
    window.addEventListener('message', (event) => {
      const msg = event.data;
      if (!msg || !msg.type) return;

      // Handle tool call from iframe
      if (msg.type === 'mcp_tool_call') {
        console.log('[Bridge] Tool call from iframe:', msg.name, 'id:', msg.id);
        console.log('[Bridge] WS state:', ws ? ws.readyState : 'null', '(0=CONNECTING, 1=OPEN, 2=CLOSING, 3=CLOSED)');
        log('out', { type: 'tool_call', name: msg.name, args: msg.args });

        // Forward to Neovim via WebSocket
        if (ws && ws.readyState === WebSocket.OPEN) {
          console.log('[Bridge] Sending tool call via WebSocket');
          ws.send(JSON.stringify({
            type: 'tool_call',
            id: msg.id,
            name: msg.name,
            args: msg.args
          }));
        } else {
          // Queue the tool call for when connection is ready
          console.log('[Bridge] WebSocket not connected, queueing tool call');
          pendingToolCalls.push(msg);
        }
        return;
      }

      // Forward other messages to Neovim
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'from_app', data: msg, origin: event.origin }));
        log('out', msg);
      }
    });

    // Process queued tool calls after connection
    function processPendingToolCalls() {
      console.log('[Bridge] Processing', pendingToolCalls.length, 'pending tool calls');
      while (pendingToolCalls.length > 0) {
        const msg = pendingToolCalls.shift();
        console.log('[Bridge] Sending queued tool call:', msg.name, 'id:', msg.id);
        ws.send(JSON.stringify({
          type: 'tool_call',
          id: msg.id,
          name: msg.name,
          args: msg.args
        }));
      }
    }

    // App content (base64 encoded to avoid escaping issues)
    const appContentBase64 = ']] .. vim.base64.encode(modified_app_content) .. [[';

    function connect() {
      console.log('[Bridge] Connecting to WebSocket at ws://127.0.0.1:' + WS_PORT);
      ws = new WebSocket('ws://127.0.0.1:' + WS_PORT);

      ws.onopen = () => {
        console.log('[Bridge] WebSocket connected!');
        setStatus(true);
        // Notify Neovim that we're ready
        ws.send(JSON.stringify({ type: 'bridge_ready' }));
        // Process any queued tool calls
        processPendingToolCalls();
      };

      ws.onclose = (event) => {
        console.log('[Bridge] WebSocket closed:', event.code, event.reason);
        setStatus(false);
        // Reconnect after 2 seconds
        reconnectTimer = setTimeout(connect, 2000);
      };

      ws.onerror = (event) => {
        console.log('[Bridge] WebSocket error:', event);
        setStatus(false);
      };

      ws.onmessage = (event) => {
        console.log('[Bridge] WS received:', event.data);
        try {
          const msg = JSON.parse(event.data);
          log('in', msg);
          console.log('[Bridge] Parsed message type:', msg.type);

          // Handle tool call response from Neovim
          if (msg.type === 'tool_response') {
            console.log('[Bridge] Forwarding tool_response to iframe, id:', msg.id);
            // Forward to iframe
            iframe.contentWindow.postMessage({
              type: 'mcp_tool_response',
              id: msg.id,
              result: msg.result,
              error: msg.error
            }, '*');
            console.log('[Bridge] postMessage sent to iframe');
          }
          // Forward other messages to iframe
          else if (msg.type === 'to_app') {
            iframe.contentWindow.postMessage(msg.data, '*');
          }
        } catch (e) {
          console.error('[Bridge] Failed to parse message:', e);
        }
      };
    }

    // Start connection first, then load iframe
    connect();

    // Load iframe content
    const appContent = atob(appContentBase64);
    iframe.srcdoc = appContent;
  </script>
</body>
</html>
]]

  return html
end

---Create a simple HTTP server to serve the bridge HTML
---@param html string HTML content to serve
---@return userdata|nil server
---@return number|nil port
---@return string|nil error
local function create_http_server(html)
  local server = uv.new_tcp()
  if not server then
    return nil, nil, "Failed to create HTTP server"
  end

  local bind_result, bind_err = server:bind("127.0.0.1", 0)
  if bind_result == nil or (type(bind_result) == "number" and bind_result ~= 0) then
    server:close()
    return nil, nil, "Failed to bind HTTP server: " .. tostring(bind_err or bind_result)
  end

  local addr = server:getsockname()
  local port = addr.port

  server:listen(128, function(listen_err)
    if listen_err then
      return
    end

    local client = uv.new_tcp()
    server:accept(client)

    client:read_start(function(read_err, data)
      if read_err or not data then
        client:close()
        return
      end

      -- Simple HTTP response
      local response = table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/html; charset=utf-8",
        "Content-Length: " .. #html,
        "Connection: close",
        "Access-Control-Allow-Origin: *",
        "",
        html
      }, "\r\n")

      client:write(response, function()
        client:close()
      end)
    end)
  end)

  return server, port, nil
end

---Open MCP App in browser with bridge
---@param ui_resource table { uri, mimeType, text, blob }
---@param mcp_server_url string
---@param opts table|nil { on_message }
---@return McpAppBridge|nil bridge
---@return string|nil error
function M.open_mcp_app(ui_resource, mcp_server_url, opts)
  opts = opts or {}

  -- Create WebSocket bridge
  local bridge, err = M.new({
    on_message = opts.on_message or function(msg)
      vim.notify("MCP App message: " .. vim.inspect(msg), vim.log.levels.DEBUG)
    end,
  })

  if not bridge then
    return nil, err
  end

  -- Generate bridge HTML
  local html = M.generate_bridge_html(ui_resource, bridge.port, mcp_server_url)

  -- Create HTTP server to serve the HTML (avoids file:// and blob: origin issues)
  local http_server, http_port, http_err = create_http_server(html)
  if not http_server then
    bridge:close()
    return nil, "Failed to create HTTP server: " .. (http_err or "unknown")
  end

  -- Store HTTP server in bridge for cleanup
  bridge.http_server = http_server
  bridge.http_port = http_port

  -- Open in browser via HTTP
  local url = "http://127.0.0.1:" .. http_port
  local open_cmd
  if vim.fn.has("mac") == 1 then
    open_cmd = { "open", url }
  elseif vim.fn.has("unix") == 1 then
    open_cmd = { "xdg-open", url }
  elseif vim.fn.has("win32") == 1 then
    open_cmd = { "cmd", "/c", "start", "", url }
  else
    bridge:close()
    return nil, "Unsupported platform"
  end

  vim.system(open_cmd, { detach = true })

  vim.notify("MCP App opened in browser", vim.log.levels.INFO)

  return bridge, nil
end

return M
