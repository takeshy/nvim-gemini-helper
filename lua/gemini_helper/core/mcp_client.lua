-- MCP (Model Context Protocol) client for Neovim
-- Implements Streamable HTTP transport
-- Reference: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http

local M = {}

local json = vim.json

---@class McpServerConfig
---@field name string Server display name
---@field url string Streamable HTTP endpoint URL
---@field headers table<string, string>|nil Optional headers for authentication
---@field enabled boolean Whether this server is enabled for chat

---@class McpToolInfo
---@field name string
---@field description string|nil
---@field inputSchema table|nil

---@class McpClient
---@field config McpServerConfig
---@field session_id string|nil
---@field request_id number
---@field initialized boolean
local McpClient = {}
McpClient.__index = McpClient

---Create a new MCP client
---@param config McpServerConfig
---@return McpClient
function M.new(config)
  local self = setmetatable({}, McpClient)
  self.config = config
  self.session_id = nil
  self.request_id = 0
  self.initialized = false
  return self
end

---Send a JSON-RPC request to the MCP server
---@param self McpClient
---@param method string
---@param params table|nil
---@return any|nil result
---@return string|nil error
function McpClient:send_request(method, params)
  self.request_id = self.request_id + 1

  local request = {
    jsonrpc = "2.0",
    id = self.request_id,
    method = method,
  }
  if params then
    request.params = params
  end

  local body_json = json.encode(request)

  -- Build curl command
  local cmd = {
    "curl", "-s", "-X", "POST", self.config.url,
    "-H", "Content-Type: application/json",
    "-H", "Accept: application/json, text/event-stream",
    "-d", body_json,
    "--max-time", "30",
  }

  -- Add custom headers
  if self.config.headers then
    for key, value in pairs(self.config.headers) do
      table.insert(cmd, "-H")
      table.insert(cmd, key .. ": " .. value)
    end
  end

  -- Add session ID header if present
  if self.session_id then
    table.insert(cmd, "-H")
    table.insert(cmd, "Mcp-Session-Id: " .. self.session_id)
  end

  -- Include response headers
  table.insert(cmd, "-i")

  -- Execute synchronously
  local result = vim.system(cmd, { text = true }):wait()

  if result.code ~= 0 then
    return nil, "curl failed: " .. (result.stderr or "unknown error")
  end

  local output = result.stdout or ""

  -- Parse headers and body
  local headers_end = output:find("\r\n\r\n", 1, true)
  local delimiter_len = 4
  if not headers_end then
    headers_end = output:find("\n\n", 1, true)
    delimiter_len = 2
  end
  if not headers_end then
    return nil, "Invalid HTTP response"
  end

  local headers_text = output:sub(1, headers_end - 1)
  local body_text = output:sub(headers_end + delimiter_len):gsub("^%s+", "")

  -- Extract session ID from headers
  local new_session_id = headers_text:match("[Mm]cp%-[Ss]ession%-[Ii]d:%s*([^\r\n]+)")
  if new_session_id then
    self.session_id = new_session_id:gsub("%s+$", "")
  end

  -- Check content type
  local content_type = headers_text:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)") or ""

  if content_type:match("text/event%-stream") then
    -- Parse SSE response
    return self:parse_sse_response(body_text)
  else
    -- Parse JSON response
    if body_text == "" then
      return nil, "Empty response"
    end

    local ok, parsed = pcall(json.decode, body_text)
    if not ok then
      return nil, "Failed to parse JSON: " .. body_text:sub(1, 100)
    end

    if parsed.error then
      return nil, string.format("MCP Error %d: %s", parsed.error.code or 0, parsed.error.message or "unknown")
    end

    return parsed.result, nil
  end
end

---Parse SSE (Server-Sent Events) response
---@param self McpClient
---@param sse_text string
---@return any|nil
---@return string|nil
function McpClient:parse_sse_response(sse_text)
  local last_data = ""

  for line in sse_text:gmatch("[^\r\n]+") do
    if line:match("^data: ") then
      last_data = line:sub(7)
    end
  end

  if last_data == "" then
    return nil, "No data received in SSE response"
  end

  local ok, parsed = pcall(json.decode, last_data)
  if not ok then
    return nil, "Failed to parse SSE data"
  end

  if parsed.error then
    return nil, string.format("MCP Error %d: %s", parsed.error.code or 0, parsed.error.message or "unknown")
  end

  return parsed.result, nil
end

---Send a notification (no response expected)
---@param self McpClient
---@param method string
---@param params table|nil
function McpClient:send_notification(method, params)
  local notification = {
    jsonrpc = "2.0",
    method = method,
  }
  if params then
    notification.params = params
  end

  local body_json = json.encode(notification)

  local cmd = {
    "curl", "-s", "-X", "POST", self.config.url,
    "-H", "Content-Type: application/json",
    "-d", body_json,
    "--max-time", "10",
  }

  if self.config.headers then
    for key, value in pairs(self.config.headers) do
      table.insert(cmd, "-H")
      table.insert(cmd, key .. ": " .. value)
    end
  end

  if self.session_id then
    table.insert(cmd, "-H")
    table.insert(cmd, "Mcp-Session-Id: " .. self.session_id)
  end

  -- Fire and forget
  vim.system(cmd, { text = true })
end

---Initialize the MCP session
---@param self McpClient
---@return table|nil result
---@return string|nil error
function McpClient:initialize()
  if self.initialized then
    return {
      protocolVersion = "2024-11-05",
      capabilities = { tools = {} },
      serverInfo = { name = self.config.name, version = "unknown" },
    }, nil
  end

  local result, err = self:send_request("initialize", {
    protocolVersion = "2024-11-05",
    capabilities = {},
    clientInfo = {
      name = "nvim-gemini-helper",
      version = "1.1.0",
    },
  })

  if err then
    return nil, err
  end

  -- Send initialized notification
  self:send_notification("notifications/initialized")

  self.initialized = true
  return result, nil
end

---List available tools from the MCP server
---@param self McpClient
---@return McpToolInfo[]|nil
---@return string|nil
function McpClient:list_tools()
  if not self.initialized then
    local _, err = self:initialize()
    if err then
      return nil, err
    end
  end

  local result, err = self:send_request("tools/list")
  if err then
    return nil, err
  end

  return result and result.tools or {}, nil
end

---Call a tool on the MCP server
---@param self McpClient
---@param tool_name string
---@param args table|nil
---@return table|nil result { content, isError, _meta }
---@return string|nil error
function McpClient:call_tool(tool_name, args)
  if not self.initialized then
    local _, err = self:initialize()
    if err then
      return nil, err
    end
  end

  -- Use vim.empty_dict() to ensure empty args is encoded as {} not []
  local arguments = args
  if arguments == nil or (type(arguments) == "table" and next(arguments) == nil) then
    arguments = vim.empty_dict()
  end

  local result, err = self:send_request("tools/call", {
    name = tool_name,
    arguments = arguments,
  })

  if err then
    return nil, err
  end

  return result, nil
end

---Read a resource from the MCP server (for ui:// resources)
---@param self McpClient
---@param uri string
---@return table|nil { uri, mimeType, text, blob }
---@return string|nil
function McpClient:read_resource(uri)
  if not self.initialized then
    local _, err = self:initialize()
    if err then
      return nil, err
    end
  end

  local result, err = self:send_request("resources/read", {
    uri = uri,
  })

  if err then
    return nil, err
  end

  if result and result.contents and result.contents[1] then
    local content = result.contents[1]
    return {
      uri = content.uri,
      mimeType = content.mimeType or "text/html",
      text = content.text,
      blob = content.blob,
    }, nil
  end

  return nil, "Resource not found"
end

---Close the MCP session
---@param self McpClient
function McpClient:close()
  if self.session_id then
    local cmd = {
      "curl", "-s", "-X", "DELETE", self.config.url,
      "--max-time", "5",
    }

    if self.config.headers then
      for key, value in pairs(self.config.headers) do
        table.insert(cmd, "-H")
        table.insert(cmd, key .. ": " .. value)
      end
    end

    table.insert(cmd, "-H")
    table.insert(cmd, "Mcp-Session-Id: " .. self.session_id)

    -- Fire and forget
    vim.system(cmd, { text = true })

    self.session_id = nil
    self.initialized = false
  end
end

---Test connection to the MCP server
---@param config McpServerConfig
---@return boolean success
---@return string|nil error
---@return string[]|nil tool_names
function M.test_connection(config)
  local client = M.new(config)

  local init_result, init_err = client:initialize()
  if init_err then
    return false, "Failed to initialize: " .. init_err, nil
  end

  local tools, tools_err = client:list_tools()
  if tools_err then
    client:close()
    return false, "Failed to list tools: " .. tools_err, nil
  end

  -- Extract tool names
  local tool_names = {}
  for _, tool in ipairs(tools or {}) do
    table.insert(tool_names, tool.name)
  end

  client:close()

  return true, nil, tool_names
end

return M
