-- Settings manager for Neovim plugin
-- Persists configuration to JSON file

local M = {}

local Path = require("plenary.path")
local json = vim.json

-- Default settings
M.defaults = {
  -- API settings
  google_api_key = "",
  model = "gemini-3.5-flash",
  api_plan = "paid",  -- "paid" or "free"

  -- Workspace settings
  workspace = vim.fn.getcwd(),

  -- Chat settings
  chats_folder = vim.fn.stdpath("data") .. "/gemini_helper/chats",
  system_prompt = "",

  -- Write permissions
  allow_write = false,

  -- Search settings
  -- search_setting can be:
  --   nil or "" = None (no search)
  --   "__websearch__" = Web Search
  --   other string = Semantic search store name
  search_setting = nil,

  -- RAG settings
  rag_only = false, -- If true, disable function calling and use only RAG

  -- Bang commands
  bang_commands = {},  -- Array of { id, name, prompt_template, description, model?, search_setting? }

  -- UI settings
  chat_width = 50,
  chat_height = 20,
  chat_position = "right", -- "right", "bottom", "center"

  -- Debug
  debug_mode = false,

  -- Auto copy response to * register
  auto_copy_response = true,

  -- CLI Provider settings
  cli_config = {
    gemini_cli_verified = false,
    claude_cli_verified = false,
    codex_cli_verified = false,
  },

  -- Session IDs for CLI providers (per-chat)
  cli_sessions = {},  -- { [chat_id] = { ["claude-cli"] = session_id, ["codex-cli"] = thread_id } }

  -- MCP (Model Context Protocol) servers
  -- Array of { name, url, headers?, enabled, tool_hints? }
  mcp_servers = {},

  -- MCP App settings
  auto_open_mcp_app = true,  -- Automatically open MCP App when returned
}

---@class SettingsManager
---@field settings table
---@field config_path string
local SettingsManager = {}
SettingsManager.__index = SettingsManager

local function normalize_deprecated_model_name(model)
  if model == "gemini-3.1-flash-lite-preview" then
    return "gemini-3.1-flash-lite"
  elseif model == "gemini-3-flash-preview" then
    return "gemini-3.5-flash"
  elseif model == "gemini-3-pro-preview" then
    return "gemini-3.1-pro-preview"
  elseif model == "gemini-2.5-flash" then
    return "gemini-3.5-flash"
  elseif model == "gemini-2.5-pro" then
    return "gemini-3.1-pro-preview"
  elseif model == "gemini-2.5-flash-lite" then
    return "gemini-3.1-flash-lite"
  end
  return model
end

---Get the config file path
---@return string
local function get_config_path()
  local config_dir = vim.fn.stdpath("data") .. "/gemini_helper"
  vim.fn.mkdir(config_dir, "p")
  return config_dir .. "/settings.json"
end

---Create a new settings manager
---@return SettingsManager
function M.new()
  local self = setmetatable({}, SettingsManager)
  self.config_path = get_config_path()
  self.settings = vim.deepcopy(M.defaults)
  return self
end

---Load settings from file
---@param self SettingsManager
---@return boolean
function SettingsManager:load()
  local path = Path:new(self.config_path)

  if not path:exists() then
    return false
  end

  local content = path:read()
  if not content or content == "" then
    return false
  end

  local ok, loaded = pcall(json.decode, content)
  if not ok then
    vim.notify("Failed to parse settings file", vim.log.levels.WARN)
    return false
  end

  -- Merge with defaults (to handle new settings)
  self.settings = vim.tbl_deep_extend("force", M.defaults, loaded)
  self.settings.model = normalize_deprecated_model_name(self.settings.model)

  for _, command in ipairs(self.settings.bang_commands or {}) do
    command.model = normalize_deprecated_model_name(command.model)
  end

  return true
end

---Save settings to file
---@param self SettingsManager
---@return boolean
function SettingsManager:save()
  local path = Path:new(self.config_path)

  -- Create a copy without transient settings (workspace should not be persisted)
  local settings_to_save = vim.deepcopy(self.settings)
  settings_to_save.workspace = nil

  local ok, encoded = pcall(json.encode, settings_to_save)
  if not ok then
    vim.notify("Failed to encode settings", vim.log.levels.ERROR)
    return false
  end

  path:write(encoded, "w")
  return true
end

---Get a setting value
---@param self SettingsManager
---@param key string
---@return any
function SettingsManager:get(key)
  return self.settings[key]
end

---Set a setting value
---@param self SettingsManager
---@param key string
---@param value any
function SettingsManager:set(key, value)
  self.settings[key] = value
end

---Update multiple settings
---@param self SettingsManager
---@param updates table
function SettingsManager:update(updates)
  for key, value in pairs(updates) do
    self.settings[key] = value
  end
end

---Reset to defaults
---@param self SettingsManager
function SettingsManager:reset()
  self.settings = vim.deepcopy(M.defaults)
end

---Validate settings
---@param self SettingsManager
---@return boolean, string|nil
function SettingsManager:validate()
  if not self.settings.google_api_key or self.settings.google_api_key == "" then
    return false, "Google API key is required"
  end

  if not self.settings.model or self.settings.model == "" then
    return false, "Model is required"
  end

  return true, nil
end

---Get all settings
---@param self SettingsManager
---@return table
function SettingsManager:get_all()
  return vim.deepcopy(self.settings)
end

---Check if Web Search is enabled
---@param self SettingsManager
---@return boolean
function SettingsManager:is_web_search_enabled()
  return self.settings.search_setting == "__websearch__"
end

---Get current search setting type
---@param self SettingsManager
---@return string "none"|"websearch"|"semantic"
function SettingsManager:get_search_type()
  local setting = self.settings.search_setting
  if not setting or setting == "" then
    return "none"
  elseif setting == "__websearch__" then
    return "websearch"
  else
    return "semantic"
  end
end

---Get bang commands
---@param self SettingsManager
---@return table[]
function SettingsManager:get_bang_commands()
  return self.settings.bang_commands or {}
end

---Add a bang command
---@param self SettingsManager
---@param command table
function SettingsManager:add_bang_command(command)
  self.settings.bang_commands = self.settings.bang_commands or {}
  -- Generate ID if not provided
  if not command.id then
    command.id = tostring(os.time()) .. "_" .. math.random(1000, 9999)
  end
  table.insert(self.settings.bang_commands, command)
end

---Remove a bang command by id
---@param self SettingsManager
---@param id string
function SettingsManager:remove_bang_command(id)
  local commands = self.settings.bang_commands or {}
  for i, cmd in ipairs(commands) do
    if cmd.id == id then
      table.remove(commands, i)
      break
    end
  end
end

---Find bang command by name
---@param self SettingsManager
---@param name string
---@return table|nil
function SettingsManager:find_bang_command(name)
  local commands = self.settings.bang_commands or {}
  for _, cmd in ipairs(commands) do
    if cmd.name == name then
      return cmd
    end
  end
  return nil
end

-- ============================================================================
-- CLI Provider Settings
-- ============================================================================

---Check if a CLI provider is verified
---@param self SettingsManager
---@param provider string  "gemini-cli", "claude-cli", or "codex-cli"
---@return boolean
function SettingsManager:is_cli_verified(provider)
  local config = self.settings.cli_config or {}
  if provider == "gemini-cli" then
    return config.gemini_cli_verified or false
  elseif provider == "claude-cli" then
    return config.claude_cli_verified or false
  elseif provider == "codex-cli" then
    return config.codex_cli_verified or false
  end
  return false
end

---Set CLI provider verification status
---@param self SettingsManager
---@param provider string
---@param verified boolean
function SettingsManager:set_cli_verified(provider, verified)
  self.settings.cli_config = self.settings.cli_config or {}
  if provider == "gemini-cli" then
    self.settings.cli_config.gemini_cli_verified = verified
  elseif provider == "claude-cli" then
    self.settings.cli_config.claude_cli_verified = verified
  elseif provider == "codex-cli" then
    self.settings.cli_config.codex_cli_verified = verified
  end
end

---Get CLI session ID for a chat
---@param self SettingsManager
---@param chat_id string
---@param provider string
---@return string|nil
function SettingsManager:get_cli_session(chat_id, provider)
  local sessions = self.settings.cli_sessions or {}
  local chat_sessions = sessions[chat_id] or {}
  return chat_sessions[provider]
end

---Set CLI session ID for a chat
---@param self SettingsManager
---@param chat_id string
---@param provider string
---@param session_id string
function SettingsManager:set_cli_session(chat_id, provider, session_id)
  self.settings.cli_sessions = self.settings.cli_sessions or {}
  self.settings.cli_sessions[chat_id] = self.settings.cli_sessions[chat_id] or {}
  self.settings.cli_sessions[chat_id][provider] = session_id
end

---Clear CLI session for a chat
---@param self SettingsManager
---@param chat_id string
function SettingsManager:clear_cli_session(chat_id)
  if self.settings.cli_sessions then
    self.settings.cli_sessions[chat_id] = nil
  end
end

---Check if any CLI provider is verified
---@param self SettingsManager
---@return boolean
function SettingsManager:has_verified_cli()
  local config = self.settings.cli_config or {}
  return config.gemini_cli_verified or config.claude_cli_verified or config.codex_cli_verified
end

---Get all verified CLI providers
---@param self SettingsManager
---@return string[]
function SettingsManager:get_verified_cli_providers()
  local providers = {}
  local config = self.settings.cli_config or {}
  if config.gemini_cli_verified then
    table.insert(providers, "gemini-cli")
  end
  if config.claude_cli_verified then
    table.insert(providers, "claude-cli")
  end
  if config.codex_cli_verified then
    table.insert(providers, "codex-cli")
  end
  return providers
end

-- ============================================================================
-- API Plan Settings
-- ============================================================================

---Get current API plan
---@param self SettingsManager
---@return string "paid" or "free"
function SettingsManager:get_api_plan()
  return self.settings.api_plan or "paid"
end

---Set API plan
---@param self SettingsManager
---@param plan string "paid" or "free"
function SettingsManager:set_api_plan(plan)
  if plan == "paid" or plan == "free" then
    self.settings.api_plan = plan
  end
end

-- ============================================================================
-- MCP Server Settings
-- ============================================================================

---Get all MCP servers
---@param self SettingsManager
---@return table[]
function SettingsManager:get_mcp_servers()
  return self.settings.mcp_servers or {}
end

---Get enabled MCP servers
---@param self SettingsManager
---@return table[]
function SettingsManager:get_enabled_mcp_servers()
  local servers = self.settings.mcp_servers or {}
  local enabled = {}
  for _, server in ipairs(servers) do
    if server.enabled then
      table.insert(enabled, server)
    end
  end
  return enabled
end

---Add an MCP server
---@param self SettingsManager
---@param server table { name, url, headers?, enabled }
function SettingsManager:add_mcp_server(server)
  self.settings.mcp_servers = self.settings.mcp_servers or {}
  -- Check for duplicate name
  for i, existing in ipairs(self.settings.mcp_servers) do
    if existing.name == server.name then
      -- Update existing
      self.settings.mcp_servers[i] = server
      return
    end
  end
  table.insert(self.settings.mcp_servers, server)
end

---Remove an MCP server by name
---@param self SettingsManager
---@param name string
function SettingsManager:remove_mcp_server(name)
  local servers = self.settings.mcp_servers or {}
  for i, server in ipairs(servers) do
    if server.name == name then
      table.remove(servers, i)
      return
    end
  end
end

---Toggle MCP server enabled status
---@param self SettingsManager
---@param name string
---@return boolean new_status
function SettingsManager:toggle_mcp_server(name)
  local servers = self.settings.mcp_servers or {}
  for _, server in ipairs(servers) do
    if server.name == name then
      server.enabled = not server.enabled
      return server.enabled
    end
  end
  return false
end

---Find MCP server by name
---@param self SettingsManager
---@param name string
---@return table|nil
function SettingsManager:find_mcp_server(name)
  local servers = self.settings.mcp_servers or {}
  for _, server in ipairs(servers) do
    if server.name == name then
      return server
    end
  end
  return nil
end

---Update MCP server tool hints (after test connection)
---@param self SettingsManager
---@param name string
---@param tool_hints string[]
function SettingsManager:update_mcp_server_tools(name, tool_hints)
  local servers = self.settings.mcp_servers or {}
  for _, server in ipairs(servers) do
    if server.name == name then
      server.tool_hints = tool_hints
      return
    end
  end
end

return M
