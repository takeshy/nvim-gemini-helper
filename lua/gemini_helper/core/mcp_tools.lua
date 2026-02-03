-- MCP Tools integration for Chat
-- Fetches tools from configured MCP servers and executes them

local M = {}

local mcp_client = require("gemini_helper.core.mcp_client")
local mcp_app_bridge = require("gemini_helper.core.mcp_app_bridge")

---@class McpToolDefinition
---@field name string Unique tool name (prefixed with server name)
---@field description string
---@field parameters table
---@field mcp_server table McpServerConfig
---@field mcp_tool_name string Original tool name on the MCP server

-- Cache for MCP tools
local tools_cache = {}
local CACHE_TTL_MS = 60000 -- 1 minute cache

---Sanitize tool names for Gemini function calling
---@param name string
---@return string
local function sanitize_tool_name(name)
  local sanitized = name:lower():gsub("[^a-z0-9_]", "_")
  sanitized = sanitized:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if sanitized == "" then
    sanitized = "tool"
  end
  return sanitized
end

---Get a unique key for an MCP server config
---@param server table McpServerConfig
---@return string
local function get_server_key(server)
  local headers_json = vim.json.encode(server.headers or {})
  return server.url .. ":" .. headers_json
end

---Convert MCP property schema to Gemini format recursively
---@param prop table
---@return table
local function convert_property_schema(prop)
  local result = {
    type = prop.type or "string",
    description = prop.description or "",
  }

  if prop.enum then
    result.enum = prop.enum
  end

  -- Handle array type - must have items for Gemini API
  if prop.type == "array" then
    if prop.items then
      local items = prop.items
      if items.type == "object" and items.properties then
        -- Array of objects
        local nested_props = {}
        for k, v in pairs(items.properties) do
          nested_props[k] = convert_property_schema(v)
        end
        result.items = {
          type = "object",
          properties = nested_props,
          required = items.required,
        }
      else
        -- Array of primitives
        result.items = {
          type = items.type or "string",
          description = items.description or "",
        }
      end
    else
      -- Default to array of strings if items not specified
      result.items = {
        type = "string",
        description = "",
      }
    end
  end

  return result
end

---Convert MCP tool to Gemini tool format
---@param tool table McpToolInfo
---@param server table McpServerConfig
---@return McpToolDefinition
local function convert_mcp_tool_to_gemini(tool, server)
  local input_schema = tool.inputSchema or {}
  local properties = {}
  local required = {}

  -- Process properties from MCP schema
  if input_schema.properties and type(input_schema.properties) == "table" then
    for key, value in pairs(input_schema.properties) do
      properties[key] = convert_property_schema(value)
    end
  end

  -- Process required fields
  if input_schema.required and type(input_schema.required) == "table" then
    for _, r in ipairs(input_schema.required) do
      table.insert(required, r)
    end
  end

  -- Create a unique tool name by prefixing with server name
  -- This avoids conflicts between tools from different servers
  local safe_name = sanitize_tool_name(server.name)
  local safe_tool_name = sanitize_tool_name(tool.name)
  local unique_name = "mcp_" .. safe_name .. "_" .. safe_tool_name

  return {
    name = unique_name,
    description = tool.description or ("MCP tool: " .. tool.name .. " from " .. server.name),
    parameters = {
      type = "object",
      properties = next(properties) and properties or vim.empty_dict(),
      required = #required > 0 and required or nil,
    },
    mcp_server = server,
    mcp_tool_name = tool.name,
  }
end

---Fetch tools from a single MCP server
---@param server table McpServerConfig
---@return McpToolDefinition[]
local function fetch_tools_from_server(server)
  local client = mcp_client.new(server)

  local ok, result = pcall(function()
    local _, init_err = client:initialize()
    if init_err then
      error(init_err)
    end

    local tools, tools_err = client:list_tools()
    if tools_err then
      error(tools_err)
    end

    client:close()
    return tools
  end)

  if not ok then
    pcall(function() client:close() end)
    vim.notify("Failed to fetch tools from MCP server " .. server.name .. ": " .. tostring(result), vim.log.levels.WARN)
    return {}
  end

  local mcp_tools = {}
  for _, tool in ipairs(result or {}) do
    table.insert(mcp_tools, convert_mcp_tool_to_gemini(tool, server))
  end

  return mcp_tools
end

---Fetch tools from all configured MCP servers
---@param servers table[] Array of McpServerConfig
---@param force_refresh boolean|nil If true, bypasses cache
---@return McpToolDefinition[]
function M.fetch_mcp_tools(servers, force_refresh)
  if not servers or #servers == 0 then
    return {}
  end

  local now = vim.loop.now()
  local cached_tools = {}
  local servers_to_fetch = {}

  for _, server in ipairs(servers) do
    if not server.enabled then
      goto continue
    end

    local cache_key = get_server_key(server)
    local cached = tools_cache[cache_key]

    -- Use cache if available and not expired
    if not force_refresh and cached and (now - cached.fetched_at) < CACHE_TTL_MS then
      for _, tool in ipairs(cached.tools) do
        table.insert(cached_tools, tool)
      end
    else
      table.insert(servers_to_fetch, server)
    end

    ::continue::
  end

  -- Fetch from servers (sequential for now)
  local fetched_tools = {}
  for _, server in ipairs(servers_to_fetch) do
    local tools = fetch_tools_from_server(server)

    -- Update cache
    local cache_key = get_server_key(server)
    tools_cache[cache_key] = {
      tools = tools,
      fetched_at = now,
    }

    for _, tool in ipairs(tools) do
      table.insert(fetched_tools, tool)
    end
  end

  -- Combine cached and freshly fetched tools
  local all_tools = {}
  for _, tool in ipairs(cached_tools) do
    table.insert(all_tools, tool)
  end
  for _, tool in ipairs(fetched_tools) do
    table.insert(all_tools, tool)
  end

  return all_tools
end

---Check if a tool is an MCP tool
---@param tool table
---@return boolean
function M.is_mcp_tool(tool)
  return tool.mcp_server ~= nil and tool.mcp_tool_name ~= nil
end

---@class McpToolResult
---@field result string|nil Text result
---@field error string|nil Error message
---@field mcp_app table|nil MCP App UI info { server_url, ui_resource }
---@field mcp_app_bridge table|nil Active MCP App bridge instance

---@class McpToolExecutor
---@field execute function(tool_name, args) -> McpToolResult
---@field cleanup function()
---@field open_mcp_app function(mcp_app) -> bridge, error

---Create an MCP tool executor with session reuse
---@param mcp_tools McpToolDefinition[]
---@return McpToolExecutor
function M.create_executor(mcp_tools)
  -- Create a map for quick lookup
  local tool_map = {}
  for _, tool in ipairs(mcp_tools) do
    tool_map[tool.name] = tool
  end

  -- Client pool keyed by server URL
  local client_pool = {}

  -- Active MCP App bridges
  local active_bridges = {}

  local function get_client(server)
    local key = get_server_key(server)
    local client = client_pool[key]

    if not client then
      client = mcp_client.new(server)
      local _, err = client:initialize()
      if err then
        error("Failed to initialize MCP client: " .. err)
      end
      client_pool[key] = client
    end

    return client
  end

  local function execute(tool_name, args)
    local tool = tool_map[tool_name]
    if not tool then
      return { error = "MCP tool not found: " .. tool_name }
    end

    local ok, result = pcall(function()
      local client = get_client(tool.mcp_server)
      local call_result, call_err = client:call_tool(tool.mcp_tool_name, args)

      if call_err then
        return { error = "MCP tool execution failed: " .. call_err }
      end

      -- Extract text content from result
      local text_contents = {}
      if call_result and call_result.content then
        for _, c in ipairs(call_result.content) do
          if c.type == "text" and c.text then
            table.insert(text_contents, c.text)
          end
        end
      end

      if call_result and call_result.isError then
        return { error = "MCP tool execution failed: " .. table.concat(text_contents, "\n") }
      end

      local mcp_result = {
        result = table.concat(text_contents, "\n"),
      }

      -- If the tool returned UI metadata, include it in the result
      if call_result and call_result._meta and call_result._meta.ui and call_result._meta.ui.resourceUri then
        -- Pre-fetch the UI resource
        local ui_resource, ui_err = client:read_resource(call_result._meta.ui.resourceUri)

        mcp_result.mcp_app = {
          server_url = tool.mcp_server.url,
          ui_resource = ui_resource,
        }

        if ui_err then
          vim.notify("Failed to fetch MCP UI resource: " .. ui_err, vim.log.levels.WARN)
        end
      end

      return mcp_result
    end)

    if not ok then
      -- On error, remove the client from pool to force reconnection on next call
      local key = get_server_key(tool.mcp_server)
      local client = client_pool[key]
      if client then
        pcall(function() client:close() end)
        client_pool[key] = nil
      end

      return { error = "MCP tool execution failed: " .. tostring(result) }
    end

    return result
  end

  local function cleanup()
    -- Close all MCP clients
    for _, client in pairs(client_pool) do
      pcall(function() client:close() end)
    end
    client_pool = {}

    -- Close all active bridges
    for _, bridge in pairs(active_bridges) do
      pcall(function() bridge:close() end)
    end
    active_bridges = {}
  end

  ---Open MCP App UI in browser with WebSocket bridge
  ---@param mcp_app table { server_url, ui_resource }
  ---@param opts table|nil { on_message }
  ---@return table|nil bridge
  ---@return string|nil error
  local function open_mcp_app(mcp_app, opts)
    if not mcp_app or not mcp_app.ui_resource then
      return nil, "No MCP App UI resource"
    end

    opts = opts or {}

    local bridge, err = mcp_app_bridge.open_mcp_app(
      mcp_app.ui_resource,
      mcp_app.server_url,
      {
        on_message = opts.on_message or function(msg)
          -- Default handler - JSON-RPC messages are handled by the caller
          if msg.jsonrpc == "2.0" and msg.method then
            vim.notify("MCP App request: " .. msg.method, vim.log.levels.DEBUG)
          end
        end,
      }
    )

    if bridge then
      table.insert(active_bridges, bridge)
    end

    return bridge, err
  end

  return {
    execute = execute,
    cleanup = cleanup,
    open_mcp_app = open_mcp_app,
  }
end

---Clear the MCP tools cache
function M.clear_cache()
  tools_cache = {}
end

---Get enabled MCP servers from list
---@param servers table[] All MCP servers
---@param enabled_names string[]|nil Names of enabled servers (nil = all enabled)
---@return table[] Filtered enabled servers
function M.get_enabled_servers(servers, enabled_names)
  if not servers then
    return {}
  end

  local result = {}

  for _, server in ipairs(servers) do
    -- Check if server is enabled in config
    if not server.enabled then
      goto continue
    end

    -- Check if server is in enabled_names list (if provided)
    if enabled_names then
      local is_in_list = false
      for _, name in ipairs(enabled_names) do
        if name == server.name then
          is_in_list = true
          break
        end
      end
      if not is_in_list then
        goto continue
      end
    end

    table.insert(result, server)

    ::continue::
  end

  return result
end

return M
