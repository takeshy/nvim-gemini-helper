-- CLI Provider abstraction layer for using CLI-based AI backends
-- Supports: Gemini CLI, Claude CLI, Codex CLI

local M = {}

local json = vim.json

-- Provider types
M.PROVIDERS = {
  "gemini-cli",
  "claude-cli",
  "codex-cli",
}

-- Provider info for UI
M.PROVIDER_INFO = {
  {
    name = "gemini-cli",
    display_name = "Gemini CLI",
    description = "Google Gemini via command line (requires Google account)",
    is_cli_model = true,
    supports_session_resumption = false,
  },
  {
    name = "claude-cli",
    display_name = "Claude CLI",
    description = "Anthropic Claude via command line (requires Anthropic account)",
    is_cli_model = true,
    supports_session_resumption = true,
  },
  {
    name = "codex-cli",
    display_name = "Codex CLI",
    description = "OpenAI Codex via command line (requires OpenAI account)",
    is_cli_model = true,
    supports_session_resumption = true,
  },
}

---Check if running on Windows
---@return boolean
local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

---Check if file exists
---@param path string
---@return boolean
local function file_exists(path)
  return vim.fn.filereadable(path) == 1
end

---Resolve Gemini CLI command and arguments
---@param args string[]
---@return string, string[]
local function resolve_gemini_command(args)
  if is_windows() then
    local appdata = vim.env.APPDATA
    if appdata then
      local script_path = appdata .. "\\npm\\node_modules\\@google\\gemini-cli\\dist\\index.js"
      local full_args = { script_path }
      for _, arg in ipairs(args) do
        table.insert(full_args, arg)
      end
      return "node", full_args
    end
  end
  -- Non-Windows: use gemini command directly
  return "gemini", args
end

---Resolve Claude CLI command and arguments
---@param args string[]
---@return string, string[]
local function resolve_claude_command(args)
  if is_windows() then
    local appdata = vim.env.APPDATA
    local localappdata = vim.env.LOCALAPPDATA

    -- Try APPDATA\npm first (npm global installs)
    if appdata then
      local script_path = appdata .. "\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js"
      local full_args = { script_path }
      for _, arg in ipairs(args) do
        table.insert(full_args, arg)
      end
      return "node", full_args
    end

    -- Fallback to LOCALAPPDATA
    if localappdata then
      local exe_path = localappdata .. "\\Programs\\claude\\claude.exe"
      return exe_path, args
    end
  else
    -- Non-Windows: check common installation paths
    local home = vim.env.HOME
    local candidate_paths = {}

    if home then
      -- Linux/Mac: ~/.local/bin/claude
      table.insert(candidate_paths, home .. "/.local/bin/claude")
      -- npm global with custom prefix
      table.insert(candidate_paths, home .. "/.npm-global/bin/claude")
    end

    -- Mac: Homebrew paths
    table.insert(candidate_paths, "/opt/homebrew/bin/claude")  -- Apple Silicon
    table.insert(candidate_paths, "/usr/local/bin/claude")     -- Intel Mac

    for _, path in ipairs(candidate_paths) do
      if file_exists(path) then
        return path, args
      end
    end
  end

  -- Fallback: use claude command directly (must be in PATH)
  return "claude", args
end

---Resolve Codex CLI command and arguments
---@param args string[]
---@return string, string[]
local function resolve_codex_command(args)
  if is_windows() then
    local appdata = vim.env.APPDATA
    if appdata then
      local script_path = appdata .. "\\npm\\node_modules\\@openai\\codex\\bin\\codex.js"
      local full_args = { script_path }
      for _, arg in ipairs(args) do
        table.insert(full_args, arg)
      end
      return "node", full_args
    end
  end
  -- Non-Windows: use codex command directly
  return "codex", args
end

---Format conversation history as a prompt string
---@param messages table[]
---@param system_prompt string
---@return string
local function format_history_as_prompt(messages, system_prompt)
  local parts = {}

  if system_prompt and system_prompt ~= "" then
    table.insert(parts, "System: " .. system_prompt .. "\n")
  end

  -- Include conversation history (excluding the last user message)
  for i = 1, #messages - 1 do
    local msg = messages[i]
    local role = msg.role == "user" and "User" or "Assistant"
    table.insert(parts, role .. ": " .. msg.content .. "\n")
  end

  -- Add the current user message
  local last_message = messages[#messages]
  if last_message and last_message.role == "user" then
    table.insert(parts, "User: " .. last_message.content)
  end

  return table.concat(parts, "\n")
end

---@class CliProvider
---@field name string
---@field display_name string
---@field supports_session_resumption boolean
---@field current_process table|nil
---@field is_aborted boolean
local CliProvider = {}
CliProvider.__index = CliProvider

---Abort current streaming request
function CliProvider:abort()
  self.is_aborted = true
  if self.current_process then
    self.current_process:kill(9)  -- SIGKILL
    self.current_process = nil
  end
end

---Check if provider is streaming
function CliProvider:is_streaming()
  return self.current_process ~= nil
end

-- ============================================================================
-- Gemini CLI Provider
-- ============================================================================

---@class GeminiCliProvider : CliProvider
local GeminiCliProvider = setmetatable({}, { __index = CliProvider })
GeminiCliProvider.__index = GeminiCliProvider

---Create new Gemini CLI provider
---@return GeminiCliProvider
function M.new_gemini_cli()
  local self = setmetatable({}, GeminiCliProvider)
  self.name = "gemini-cli"
  self.display_name = "Gemini CLI"
  self.supports_session_resumption = false
  self.current_process = nil
  self.is_aborted = false
  return self
end

---Check if Gemini CLI is available
---@return boolean
function GeminiCliProvider:is_available()
  local command, args = resolve_gemini_command({ "--version" })
  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end
  local result = vim.system(cmd_table, { text = true }):wait(30000)
  return result.code == 0
end

---Stream chat response
---@param opts table
function GeminiCliProvider:chat_stream(opts)
  local messages = opts.messages or {}
  local system_prompt = opts.system_prompt or ""
  local working_directory = opts.working_directory or vim.fn.getcwd()
  local on_chunk = opts.on_chunk
  local on_done = opts.on_done
  local on_error = opts.on_error

  local prompt = format_history_as_prompt(messages, system_prompt)
  local command, args = resolve_gemini_command({ "-p", prompt })

  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  self.is_aborted = false
  local accumulated_text = ""

  self.current_process = vim.system(
    cmd_table,
    {
      cwd = working_directory,
      text = true,
      stdout = function(err, data)
        if err or not data then return end
        accumulated_text = accumulated_text .. data
        if on_chunk then
          vim.schedule(function()
            on_chunk({ type = "text", content = data })
          end)
        end
      end,
      stderr = function(err, data)
        -- Log stderr for debugging if needed
      end,
    },
    function(result)
      self.current_process = nil
      vim.schedule(function()
        if self.is_aborted then
          if on_done then
            on_done({ text = accumulated_text, aborted = true })
          end
          return
        end

        if result.code ~= 0 then
          if on_error then
            on_error("Gemini CLI exited with code " .. result.code)
          end
          return
        end

        if on_done then
          on_done({ text = accumulated_text })
        end
      end)
    end
  )
end

-- ============================================================================
-- Claude CLI Provider
-- ============================================================================

---@class ClaudeCliProvider : CliProvider
local ClaudeCliProvider = setmetatable({}, { __index = CliProvider })
ClaudeCliProvider.__index = ClaudeCliProvider

---Create new Claude CLI provider
---@return ClaudeCliProvider
function M.new_claude_cli()
  local self = setmetatable({}, ClaudeCliProvider)
  self.name = "claude-cli"
  self.display_name = "Claude CLI"
  self.supports_session_resumption = true
  self.current_process = nil
  self.is_aborted = false
  return self
end

---Check if Claude CLI is available
---@return boolean
function ClaudeCliProvider:is_available()
  local command, args = resolve_claude_command({ "--version" })
  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end
  local result = vim.system(cmd_table, { text = true }):wait(30000)
  return result.code == 0
end

---Stream chat response with session support
---@param opts table
function ClaudeCliProvider:chat_stream(opts)
  local messages = opts.messages or {}
  local system_prompt = opts.system_prompt or ""
  local working_directory = opts.working_directory or vim.fn.getcwd()
  local session_id = opts.session_id
  local on_chunk = opts.on_chunk
  local on_done = opts.on_done
  local on_error = opts.on_error

  -- Build CLI arguments based on whether we have a session ID
  local cli_args

  if session_id then
    -- Resuming existing session - only send latest message
    local last_message = messages[#messages]
    local prompt = last_message and last_message.role == "user" and last_message.content or ""
    cli_args = { "--resume", session_id, "-p", prompt, "--output-format", "stream-json", "--verbose" }
  else
    -- First message - send full history
    local prompt = format_history_as_prompt(messages, system_prompt)
    cli_args = { "-p", prompt, "--output-format", "stream-json", "--verbose" }
  end

  local command, args = resolve_claude_command(cli_args)

  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  self.is_aborted = false
  local accumulated_text = ""
  local buffer = ""
  local session_id_emitted = false
  local new_session_id = nil

  self.current_process = vim.system(
    cmd_table,
    {
      cwd = working_directory,
      text = true,
      stdin = "",  -- Close stdin immediately
      stdout = function(err, data)
        if err or not data then return end
        buffer = buffer .. data

        -- Process complete JSON lines
        while true do
          local line_end = buffer:find("\n")
          if not line_end then break end

          local line = buffer:sub(1, line_end - 1)
          buffer = buffer:sub(line_end + 1)

          if line:match("^%s*$") then goto continue end

          local ok, parsed = pcall(json.decode, line)
          if ok and parsed then
            -- Handle different message types from Claude CLI stream-json format
            if parsed.type == "assistant" then
              local message = parsed.message
              if message and message.content then
                for _, block in ipairs(message.content) do
                  if block.type == "text" and block.text then
                    accumulated_text = accumulated_text .. block.text
                    if on_chunk then
                      vim.schedule(function()
                        on_chunk({ type = "text", content = block.text })
                      end)
                    end
                  end
                end
              end
            elseif parsed.type == "content_block_delta" then
              local delta = parsed.delta
              if delta and delta.type == "text_delta" and delta.text then
                accumulated_text = accumulated_text .. delta.text
                if on_chunk then
                  vim.schedule(function()
                    on_chunk({ type = "text", content = delta.text })
                  end)
                end
              end
            elseif parsed.type == "error" then
              local error_obj = parsed.error
              local error_msg = error_obj and error_obj.message or parsed.message or "Unknown error"
              if on_chunk then
                vim.schedule(function()
                  on_chunk({ type = "error", error = error_msg })
                end)
              end
            end

            -- Extract session_id
            if not session_id_emitted then
              local sid = nil
              if parsed.session_id then
                sid = parsed.session_id
              elseif parsed.type == "result" and parsed.data and parsed.data.session_id then
                sid = parsed.data.session_id
              end
              if sid then
                new_session_id = sid
                session_id_emitted = true
                if on_chunk then
                  vim.schedule(function()
                    on_chunk({ type = "session_id", session_id = sid })
                  end)
                end
              end
            end
          end

          ::continue::
        end
      end,
      stderr = function(err, data)
        -- Log stderr for debugging
      end,
    },
    function(result)
      self.current_process = nil
      vim.schedule(function()
        if on_done then
          on_done({
            text = accumulated_text,
            session_id = new_session_id,
            aborted = self.is_aborted,
          })
        end
      end)
    end
  )
end

-- ============================================================================
-- Codex CLI Provider
-- ============================================================================

---@class CodexCliProvider : CliProvider
local CodexCliProvider = setmetatable({}, { __index = CliProvider })
CodexCliProvider.__index = CodexCliProvider

---Create new Codex CLI provider
---@return CodexCliProvider
function M.new_codex_cli()
  local self = setmetatable({}, CodexCliProvider)
  self.name = "codex-cli"
  self.display_name = "Codex CLI"
  self.supports_session_resumption = true
  self.current_process = nil
  self.is_aborted = false
  return self
end

---Check if Codex CLI is available
---@return boolean
function CodexCliProvider:is_available()
  local command, args = resolve_codex_command({ "--version" })
  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end
  local result = vim.system(cmd_table, { text = true }):wait(30000)
  return result.code == 0
end

---Stream chat response with session support
---@param opts table
function CodexCliProvider:chat_stream(opts)
  local messages = opts.messages or {}
  local system_prompt = opts.system_prompt or ""
  local working_directory = opts.working_directory or vim.fn.getcwd()
  local session_id = opts.session_id
  local on_chunk = opts.on_chunk
  local on_done = opts.on_done
  local on_error = opts.on_error

  -- Build CLI arguments
  local cli_args

  if session_id then
    -- Resuming existing session
    local last_message = messages[#messages]
    local prompt = last_message and last_message.role == "user" and last_message.content or ""
    cli_args = { "exec", "--json", "--skip-git-repo-check", "resume", session_id, prompt }
  else
    -- First message
    local prompt = format_history_as_prompt(messages, system_prompt)
    cli_args = { "exec", "--json", "--skip-git-repo-check", prompt }
  end

  local command, args = resolve_codex_command(cli_args)

  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  self.is_aborted = false
  local accumulated_text = ""
  local buffer = ""
  local session_id_emitted = false
  local new_session_id = nil

  self.current_process = vim.system(
    cmd_table,
    {
      cwd = working_directory,
      text = true,
      stdin = "",  -- Close stdin immediately
      stdout = function(err, data)
        if err or not data then return end
        buffer = buffer .. data

        -- Process complete JSON lines
        while true do
          local line_end = buffer:find("\n")
          if not line_end then break end

          local line = buffer:sub(1, line_end - 1)
          buffer = buffer:sub(line_end + 1)

          if line:match("^%s*$") then goto continue end

          local ok, parsed = pcall(json.decode, line)
          if ok and parsed then
            -- Handle thread.started event - extract thread_id for session resumption
            if parsed.type == "thread.started" and parsed.thread_id then
              if not session_id_emitted then
                new_session_id = parsed.thread_id
                session_id_emitted = true
                if on_chunk then
                  vim.schedule(function()
                    on_chunk({ type = "session_id", session_id = parsed.thread_id })
                  end)
                end
              end
            elseif parsed.type == "item.completed" then
              local item = parsed.item
              if item and item.type == "agent_message" and item.text then
                accumulated_text = accumulated_text .. item.text
                if on_chunk then
                  vim.schedule(function()
                    on_chunk({ type = "text", content = item.text })
                  end)
                end
              end
            elseif parsed.type == "error" then
              local error_msg = parsed.message or parsed.error or "Unknown error"
              if on_chunk then
                vim.schedule(function()
                  on_chunk({ type = "error", error = error_msg })
                end)
              end
            end
          end

          ::continue::
        end
      end,
      stderr = function(err, data)
        -- Log stderr for debugging
      end,
    },
    function(result)
      self.current_process = nil
      vim.schedule(function()
        if on_done then
          on_done({
            text = accumulated_text,
            session_id = new_session_id,
            aborted = self.is_aborted,
          })
        end
      end)
    end
  )
end

-- ============================================================================
-- CLI Provider Manager
-- ============================================================================

---@class CliProviderManager
---@field providers table<string, CliProvider>
local CliProviderManager = {}
CliProviderManager.__index = CliProviderManager

---Create new CLI provider manager
---@return CliProviderManager
function M.new_manager()
  local self = setmetatable({}, CliProviderManager)
  self.providers = {
    ["gemini-cli"] = M.new_gemini_cli(),
    ["claude-cli"] = M.new_claude_cli(),
    ["codex-cli"] = M.new_codex_cli(),
  }
  return self
end

---Get provider by name
---@param name string
---@return CliProvider|nil
function CliProviderManager:get_provider(name)
  return self.providers[name]
end

---Get available providers (synchronous check)
---@return string[]
function CliProviderManager:get_available_providers()
  local available = {}
  for name, provider in pairs(self.providers) do
    if provider:is_available() then
      table.insert(available, name)
    end
  end
  return available
end

---Check if provider is available
---@param name string
---@return boolean
function CliProviderManager:is_provider_available(name)
  local provider = self.providers[name]
  if not provider then return false end
  return provider:is_available()
end

-- ============================================================================
-- Verification Functions
-- ============================================================================

---@class CliVerifyResult
---@field success boolean
---@field stage string  "version" or "login"
---@field error string|nil

---Verify Gemini CLI installation and login
---@return CliVerifyResult
function M.verify_gemini_cli()
  -- Step 1: Check --version
  local command, args = resolve_gemini_command({ "--version" })
  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  local version_result = vim.system(cmd_table, { text = true }):wait(30000)
  if version_result.code ~= 0 then
    return {
      success = false,
      stage = "version",
      error = "Gemini CLI not found. Install it with `npm install -g @google/gemini-cli`",
    }
  end

  -- Step 2: Test with simple prompt
  command, args = resolve_gemini_command({ "-p", "Hello" })
  cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  local login_result = vim.system(cmd_table, { text = true }):wait(60000)
  if login_result.code ~= 0 then
    return {
      success = false,
      stage = "login",
      error = "Please run 'gemini' in terminal to log in with your Google account",
    }
  end

  return { success = true, stage = "login" }
end

---Verify Claude CLI installation and login
---@return CliVerifyResult
function M.verify_claude_cli()
  -- Step 1: Check --version
  local command, args = resolve_claude_command({ "--version" })
  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  local version_result = vim.system(cmd_table, { text = true }):wait(30000)
  if version_result.code ~= 0 then
    return {
      success = false,
      stage = "version",
      error = "Claude CLI not found. Install it with `npm install -g @anthropic-ai/claude-code`",
    }
  end

  -- Step 2: Test with simple prompt
  command, args = resolve_claude_command({ "-p", "Hello", "--output-format", "text" })
  cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  local login_result = vim.system(cmd_table, { text = true }):wait(60000)
  if login_result.code ~= 0 then
    return {
      success = false,
      stage = "login",
      error = "Please run 'claude' in terminal to log in with your Anthropic account",
    }
  end

  return { success = true, stage = "login" }
end

---Verify Codex CLI installation and login
---@return CliVerifyResult
function M.verify_codex_cli()
  -- Step 1: Check --version
  local command, args = resolve_codex_command({ "--version" })
  local cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  local version_result = vim.system(cmd_table, { text = true }):wait(30000)
  if version_result.code ~= 0 then
    return {
      success = false,
      stage = "version",
      error = "Codex CLI not found. Install it with `npm install -g @openai/codex`",
    }
  end

  -- Step 2: Test with simple prompt
  command, args = resolve_codex_command({ "exec", "Hello", "--json", "--skip-git-repo-check" })
  cmd_table = { command }
  for _, arg in ipairs(args) do
    table.insert(cmd_table, arg)
  end

  local login_result = vim.system(cmd_table, { text = true }):wait(60000)
  if login_result.code ~= 0 then
    return {
      success = false,
      stage = "login",
      error = "Please run 'codex' in terminal to log in with your OpenAI account",
    }
  end

  return { success = true, stage = "login" }
end

-- ============================================================================
-- Helper Functions
-- ============================================================================

---Check if a model is a CLI model
---@param model string
---@return boolean
function M.is_cli_model(model)
  return model == "gemini-cli" or model == "claude-cli" or model == "codex-cli"
end

---Get CLI provider type from model name
---@param model string
---@return string|nil
function M.get_provider_type(model)
  if model == "gemini-cli" then return "gemini-cli" end
  if model == "claude-cli" then return "claude-cli" end
  if model == "codex-cli" then return "codex-cli" end
  return nil
end

---Get provider info by name
---@param name string
---@return table|nil
function M.get_provider_info(name)
  for _, info in ipairs(M.PROVIDER_INFO) do
    if info.name == name then
      return info
    end
  end
  return nil
end

return M
