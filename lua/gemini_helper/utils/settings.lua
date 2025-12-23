-- Settings manager for Neovim plugin
-- Persists configuration to JSON file

local M = {}

local Path = require("plenary.path")
local json = vim.json

-- Default settings
M.defaults = {
  -- API settings
  google_api_key = "",
  model = "gemini-3-flash-preview",

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

  -- RAG settings (use store created by ragujuary)
  rag_enabled = false,
  rag_store_name = nil, -- e.g. "fileSearchStores/your-store-name"
  rag_only = false, -- If true, disable function calling and use only RAG

  -- Slash commands
  slash_commands = {},  -- Array of { id, name, prompt_template, model, description, search_setting }

  -- UI settings
  chat_width = 50,
  chat_height = 20,
  chat_position = "right", -- "right", "bottom", "center"

  -- Debug
  debug_mode = false,
}

---@class SettingsManager
---@field settings table
---@field config_path string
local SettingsManager = {}
SettingsManager.__index = SettingsManager

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

---Check if RAG is configured
---@param self SettingsManager
---@return boolean
function SettingsManager:is_rag_configured()
  return self.settings.rag_enabled and self.settings.rag_store_name ~= nil
end

---Get RAG store name with proper format
---@param self SettingsManager
---@return string|nil
function SettingsManager:get_rag_store_name()
  local store_name = self.settings.rag_store_name
  if not store_name then
    return nil
  end
  -- Auto-prepend fileSearchStores/ if not present
  if not store_name:match("^fileSearchStores/") then
    store_name = "fileSearchStores/" .. store_name
  end
  return store_name
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

---Get slash commands
---@param self SettingsManager
---@return table[]
function SettingsManager:get_slash_commands()
  return self.settings.slash_commands or {}
end

---Add a slash command
---@param self SettingsManager
---@param command table
function SettingsManager:add_slash_command(command)
  self.settings.slash_commands = self.settings.slash_commands or {}
  -- Generate ID if not provided
  if not command.id then
    command.id = tostring(os.time()) .. "_" .. math.random(1000, 9999)
  end
  table.insert(self.settings.slash_commands, command)
end

---Remove a slash command by id
---@param self SettingsManager
---@param id string
function SettingsManager:remove_slash_command(id)
  local commands = self.settings.slash_commands or {}
  for i, cmd in ipairs(commands) do
    if cmd.id == id then
      table.remove(commands, i)
      break
    end
  end
end

---Find slash command by name
---@param self SettingsManager
---@param name string
---@return table|nil
function SettingsManager:find_slash_command(name)
  local commands = self.settings.slash_commands or {}
  for _, cmd in ipairs(commands) do
    if cmd.name == name then
      return cmd
    end
  end
  return nil
end

return M
