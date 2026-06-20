-- Gemini Helper for Neovim
-- Main plugin entry point

local M = {}

M.version = "1.3.0"

-- Module imports
local gemini = require("gemini_helper.core.gemini")
local cli_provider = require("gemini_helper.core.cli_provider")
local tools = require("gemini_helper.core.tools")
local mcp_tools = require("gemini_helper.core.mcp_tools")
local mcp_client = require("gemini_helper.core.mcp_client")
local mcp_app_bridge = require("gemini_helper.core.mcp_app_bridge")
local notes = require("gemini_helper.vault.notes")
local search = require("gemini_helper.vault.search")
local tool_executor = require("gemini_helper.vault.tool_executor")
local settings_mod = require("gemini_helper.utils.settings")
local history = require("gemini_helper.utils.history")
local chat_ui = require("gemini_helper.ui.chat")

-- Plugin state
local state = {
  settings = nil,
  gemini_client = nil,
  cli_manager = nil,  -- CLI Provider Manager
  notes_manager = nil,
  search_manager = nil,
  executor = nil,
  history_manager = nil,
  chat = nil,
  current_chat_id = nil,
  original_bufnr = nil,  -- Buffer that was active before opening chat
  mcp_executor = nil,  -- MCP Tool Executor
  mcp_tools_cache = nil,  -- Cached MCP tools
  last_mcp_apps = nil,  -- Last MCP Apps with UI resources
  active_mcp_bridges = {},  -- Active MCP App WebSocket bridges
}

-- Default system prompt
local DEFAULT_SYSTEM_PROMPT = [[You are a helpful AI assistant integrated with Neovim. You can help with:
- Reading and editing files in the workspace
- Searching for notes and content
- Creating new notes and folders
- Answering questions about the codebase

You have access to two sources of information:
1. Local workspace files (via search_notes, read_note tools)
2. RAG file search store (automatically searched and provided as context)

If local search returns no results, use the RAG context to answer the question.
Do not repeatedly call search_notes if it returns empty results - use RAG context instead.

Be concise and helpful. Focus on the task at hand.]]

---Initialize the plugin
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}

  -- Initialize settings
  state.settings = settings_mod.new()
  state.settings:load()

  -- Apply user opts
  if opts.api_key then
    state.settings:set("google_api_key", opts.api_key)
  end
  if opts.model then
    state.settings:set("model", opts.model)
  end
  -- Workspace is always current directory at startup (not saved to settings file)
  local workspace = opts.workspace or vim.fn.getcwd()
  state.settings:set("workspace", workspace)
  if opts.allow_write ~= nil then
    state.settings:set("allow_write", opts.allow_write)
  end
  if opts.system_prompt then
    state.settings:set("system_prompt", opts.system_prompt)
  end
  if opts.search_setting then
    state.settings:set("search_setting", opts.search_setting)
  end
  -- Handle commands (bang commands)
  local cmds = opts.commands
  if cmds then
    -- Replace existing commands with those from opts
    state.settings:set("bang_commands", {})
    for _, cmd in ipairs(cmds) do
      state.settings:add_bang_command(cmd)
    end
  end

  -- Save settings
  state.settings:save()

  -- Initialize managers
  local workspace = state.settings:get("workspace")

  state.notes_manager = notes.new(workspace)
  state.search_manager = search.new(workspace)
  state.history_manager = history.new(state.settings:get("chats_folder"))

  -- Initialize Gemini client if API key is set
  local api_key = state.settings:get("google_api_key")
  if api_key and api_key ~= "" then
    state.gemini_client = gemini.new(api_key, state.settings:get("model"))
  end

  -- Initialize CLI provider manager
  state.cli_manager = cli_provider.new_manager()

  -- Initialize tool executor
  state.executor = tool_executor.new(
    state.notes_manager,
    state.search_manager,
    state.settings:get_all()
  )

  -- Register commands
  M.register_commands()

  -- Create user commands
  vim.api.nvim_create_user_command("GeminiChat", function(cmd_opts)
    -- If range is specified, capture selection from range
    local initial_input = nil
    if cmd_opts.range == 2 then
      local lines = vim.api.nvim_buf_get_lines(0, cmd_opts.line1 - 1, cmd_opts.line2, false)
      initial_input = table.concat(lines, "\n")
    end
    M.open_chat(initial_input)
  end, { range = true, desc = "Open Gemini chat" })

  vim.api.nvim_create_user_command("GeminiNewChat", function()
    M.new_chat()
  end, { desc = "Start new Gemini chat" })

  vim.api.nvim_create_user_command("GeminiHistory", function()
    M.show_history()
  end, { desc = "Show chat history" })

  vim.api.nvim_create_user_command("GeminiSettings", function()
    M.show_settings()
  end, { desc = "Show Gemini settings" })

  vim.api.nvim_create_user_command("GeminiSetApiKey", function(cmd_opts)
    M.set_api_key(cmd_opts.args)
  end, { nargs = 1, desc = "Set Google API key" })

  vim.api.nvim_create_user_command("GeminiToggleWrite", function()
    M.toggle_write()
  end, { desc = "Toggle write permissions" })

  vim.api.nvim_create_user_command("GeminiTest", function()
    M.test_api()
  end, { desc = "Test Gemini API connection" })

  vim.api.nvim_create_user_command("GeminiBangCommands", function(cmd_opts)
    -- If range is specified, capture selection from range
    local selection = nil
    if cmd_opts.range == 2 then
      local lines = vim.api.nvim_buf_get_lines(0, cmd_opts.line1 - 1, cmd_opts.line2, false)
      selection = table.concat(lines, "\n")
    end
    M.show_bang_commands(selection)
  end, { range = true, desc = "Show bang commands picker" })

  vim.api.nvim_create_user_command("GeminiAddBangCommand", function(cmd_opts)
    local args = cmd_opts.args
    local name, template = args:match("^(%S+)%s+(.+)$")
    if name and template then
      M.add_bang_command({ name = name, prompt_template = template })
    else
      vim.notify("Usage: :GeminiAddBangCommand <name> <template>", vim.log.levels.ERROR)
    end
  end, { nargs = "+", desc = "Add a bang command" })

  vim.api.nvim_create_user_command("GeminiWebSearch", function()
    state.settings:set("search_setting", "__websearch__")
    vim.notify("Web Search enabled for next message", vim.log.levels.INFO)
  end, { desc = "Enable Web Search for next message" })

  vim.api.nvim_create_user_command("GeminiSearchNone", function()
    state.settings:set("search_setting", nil)
    vim.notify("Search disabled", vim.log.levels.INFO)
  end, { desc = "Disable search" })

  vim.api.nvim_create_user_command("GeminiDebug", function()
    local current = state.settings:get("debug_mode")
    state.settings:set("debug_mode", not current)
    vim.notify("Debug mode: " .. (not current and "ON" or "OFF"), vim.log.levels.INFO)
  end, { desc = "Toggle debug mode" })

  vim.api.nvim_create_user_command("GeminiSetApiPlan", function(cmd_opts)
    local plan = cmd_opts.args
    if plan ~= "paid" and plan ~= "free" then
      vim.notify("Invalid plan. Use 'paid' or 'free'", vim.log.levels.ERROR)
      return
    end
    state.settings:set_api_plan(plan)
    -- Validate current model is allowed for new plan
    local current_model = state.settings:get("model")
    if not gemini.is_model_allowed_for_plan(plan, current_model) then
      local new_default = gemini.get_models_for_plan(plan)[1].name
      state.settings:set("model", new_default)
      vim.notify("Model changed to " .. new_default .. " (previous model not available in " .. plan .. " plan)", vim.log.levels.WARN)
    end
    state.settings:save()
    vim.notify("API plan set to: " .. plan, vim.log.levels.INFO)
  end, { nargs = 1, desc = "Set API plan (paid or free)" })

  -- CLI Provider verification commands
  vim.api.nvim_create_user_command("GeminiVerifyGeminiCli", function()
    M.verify_cli("gemini-cli")
  end, { desc = "Verify Gemini CLI installation" })

  vim.api.nvim_create_user_command("GeminiVerifyClaudeCli", function()
    M.verify_cli("claude-cli")
  end, { desc = "Verify Claude CLI installation" })

  vim.api.nvim_create_user_command("GeminiVerifyCodexCli", function()
    M.verify_cli("codex-cli")
  end, { desc = "Verify Codex CLI installation" })

  -- MCP Server commands
  vim.api.nvim_create_user_command("GeminiMcpAdd", function(cmd_opts)
    local args = cmd_opts.args
    local name, url = args:match("^(%S+)%s+(%S+)$")
    if name and url then
      M.add_mcp_server({ name = name, url = url })
    else
      vim.notify("Usage: :GeminiMcpAdd <name> <url>", vim.log.levels.ERROR)
    end
  end, { nargs = "+", desc = "Add an MCP server" })

  vim.api.nvim_create_user_command("GeminiMcpList", function()
    M.list_mcp_servers()
  end, { desc = "List MCP servers" })

  vim.api.nvim_create_user_command("GeminiMcpTest", function(cmd_opts)
    local name = cmd_opts.args
    if name and name ~= "" then
      M.test_mcp_server(name)
    else
      vim.notify("Usage: :GeminiMcpTest <server_name>", vim.log.levels.ERROR)
    end
  end, { nargs = 1, desc = "Test MCP server connection" })

  vim.api.nvim_create_user_command("GeminiMcpToggle", function(cmd_opts)
    local name = cmd_opts.args
    if name and name ~= "" then
      M.toggle_mcp_server(name)
    else
      vim.notify("Usage: :GeminiMcpToggle <server_name>", vim.log.levels.ERROR)
    end
  end, { nargs = 1, desc = "Toggle MCP server enabled status" })

  vim.api.nvim_create_user_command("GeminiMcpRemove", function(cmd_opts)
    local name = cmd_opts.args
    if name and name ~= "" then
      M.remove_mcp_server(name)
    else
      vim.notify("Usage: :GeminiMcpRemove <server_name>", vim.log.levels.ERROR)
    end
  end, { nargs = 1, desc = "Remove an MCP server" })

  vim.api.nvim_create_user_command("GeminiMcpAppOpen", function()
    M.open_mcp_app()
  end, { desc = "Open last MCP App in browser" })

  vim.api.nvim_create_user_command("GeminiMcpAppClose", function()
    M.close_mcp_app_bridges()
  end, { desc = "Close all MCP App bridges" })

  vim.api.nvim_create_user_command("GeminiMcpAppAutoOpen", function()
    local current = state.settings:get("auto_open_mcp_app")
    state.settings:set("auto_open_mcp_app", not current)
    state.settings:save()
    vim.notify("Auto-open MCP App: " .. (not current and "ON" or "OFF"), vim.log.levels.INFO)
  end, { desc = "Toggle auto-open MCP App in browser" })

  vim.notify("Gemini Helper loaded", vim.log.levels.INFO)
end

---Register keymaps
function M.register_commands()
  -- Default keymaps (can be overridden in setup)
  vim.keymap.set("n", "<leader>gc", M.open_chat, { desc = "Open Gemini chat" })
  vim.keymap.set("n", "<leader>gn", M.new_chat, { desc = "New Gemini chat" })
  vim.keymap.set("n", "<leader>gh", M.show_history, { desc = "Gemini history" })
  vim.keymap.set("n", "<leader>gs", M.show_settings, { desc = "Gemini settings" })
  vim.keymap.set("n", "<leader>g/", M.show_bang_commands, { desc = "Gemini bang commands" })
  vim.keymap.set("v", "<leader>gc", ":'<,'>GeminiChat<CR>", { desc = "Open Gemini chat with selection" })
  vim.keymap.set("v", "<leader>g/", ":'<,'>GeminiBangCommands<CR>", { desc = "Gemini bang commands with selection" })

  -- Global toggle chat with Ctrl+\
  vim.keymap.set({ "n", "i" }, "<C-\\>", function()
    if state.chat and state.chat:is_open() then
      -- Chat is open, will be handled by chat's own keymap
      state.chat:focus_input()
    else
      -- Chat is not open, open it
      M.open_chat()
    end
  end, { desc = "Toggle Gemini chat" })
end

local function save_current_chat()
  if not state.chat or not state.history_manager then
    return
  end

  local messages = state.chat:get_messages()
  if #messages == 0 then
    return
  end

  if not state.current_chat_id then
    state.current_chat_id = state.history_manager:create_new()
  end

  state.history_manager:save(state.current_chat_id, messages)
end

---Open chat window
---@param initial_input string|nil  Optional initial text for input
function M.open_chat(initial_input)
  -- Check if we have either API key or verified CLI provider
  local has_api = state.gemini_client ~= nil
  local has_cli = state.settings and state.settings:has_verified_cli()

  if not has_api and not has_cli then
    vim.notify(
      "Please set your Google API key with :GeminiSetApiKey or verify a CLI provider with :GeminiVerifyClaudeCli",
      vim.log.levels.WARN
    )
    return
  end

  -- Save the original window and buffer before opening chat
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()
  -- Only save if not the chat window itself
  local is_chat_win = state.chat and (
    current_win == state.chat.input_win or
    current_win == state.chat.main_win or
    current_win == state.chat.settings_win
  )
  if not is_chat_win then
    state.original_bufnr = current_buf
    state.original_win = current_win
  end

  -- Create chat UI if not exists
  if not state.chat then
    state.chat = chat_ui.new({
      width = state.settings:get("chat_width"),
      height = state.settings:get("chat_height"),
      position = state.settings:get("chat_position"),
      model_name = state.settings:get("model"),
      on_send = function(message, pending_settings)
        -- If user typed !command directly, expand it
        local final_message = M.process_bang_command(message)
        -- Use pending_settings if provided
        M.handle_message(final_message, pending_settings)
      end,
      on_stop = function()
        -- Stop API client
        if state.gemini_client then
          state.gemini_client:abort()
        end
        -- Stop CLI providers
        if state.cli_manager then
          for _, provider_name in ipairs(cli_provider.PROVIDERS) do
            local provider = state.cli_manager:get_provider(provider_name)
            if provider and provider:is_streaming() then
              provider:abort()
            end
          end
        end
        vim.notify("Generation stopped", vim.log.levels.INFO)
      end,
      on_get_bang_commands = function()
        return state.settings:get_bang_commands()
      end,
      on_get_files = function()
        -- Get files from workspace
        local workspace = state.settings:get("workspace")
        local files = {}
        local handle = vim.loop.fs_scandir(workspace)
        if handle then
          while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            if type == "file" then
              table.insert(files, name)
            elseif type == "directory" and not name:match("^%.") then
              -- Add directory with trailing /
              table.insert(files, name .. "/")
            end
          end
        end
        table.sort(files)
        return files
      end,
      on_get_default_settings = function()
        return {
          model = state.settings:get("model"),
          search_setting = state.settings:get("search_setting"),
          auto_copy_response = state.settings:get("auto_copy_response"),
        }
      end,
      on_get_original_win = function()
        if state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
          return state.original_win
        end
        return nil
      end,
      on_fetch_rag_stores = function(callback)
        local api_key = state.settings:get("google_api_key")
        if not api_key or api_key == "" then
          callback(nil, "API key not set")
          return
        end
        gemini.list_file_search_stores(api_key, callback)
      end,
      on_get_mcp_servers = function()
        return state.settings:get_mcp_servers()
      end,
      available_models = M.get_available_models(),
    })
  end

  if not state.chat:is_open() then
    state.chat:open()

    -- Load last chat if exists
    if state.current_chat_id then
      local metadata, messages = state.history_manager:load(state.current_chat_id)
      if messages then
        state.chat:set_messages(messages)
      end
    end
  else
    -- Chat already open, just focus input
    state.chat:focus_input()
  end

  -- Set initial input if provided (with empty line at top for !command)
  if initial_input and initial_input ~= "" and state.chat then
    -- Add empty line at top so user can type !command
    state.chat:set_input("\n" .. initial_input)
    -- Cursor stays at line 1, col 0 (beginning)
  end
end

---Start new chat
function M.new_chat()
  -- Save current chat if exists
  save_current_chat()

  state.current_chat_id = state.history_manager:create_new()

  if state.chat and state.chat:is_open() then
    state.chat:clear()
  else
    M.open_chat()
  end
end

---Handle incoming message
---@param message string
---@param opts table|nil  Optional overrides for model, search_setting
function M.handle_message(message, opts)
  opts = opts or {}

  -- Determine which model to use
  local model = opts.model or state.settings:get("model")

  -- Check if this is a CLI model
  if cli_provider.is_cli_model(model) then
    return M.handle_cli_message(message, opts, model)
  end

  -- API-based message handling
  if not state.gemini_client then
    vim.notify("Gemini client not initialized", vim.log.levels.ERROR)
    return
  end

  state.chat:start_streaming()

  -- Determine search settings (can be string or array)
  local search_setting = opts.search_setting or state.settings:get("search_setting")

  -- Normalize to array
  local search_settings = {}
  if search_setting then
    if type(search_setting) == "table" then
      search_settings = search_setting
    elseif search_setting ~= "" then
      search_settings = { search_setting }
    end
  end

  -- Check for web search and extract RAG store names
  local web_search_enabled = false
  local rag_store_names = {}
  for _, setting in ipairs(search_settings) do
    if setting == "__websearch__" then
      web_search_enabled = true
    elseif setting and setting ~= "" then
      -- RAG store name
      local store_name = setting
      if not store_name:match("^fileSearchStores/") then
        store_name = "fileSearchStores/" .. store_name
      end
      table.insert(rag_store_names, store_name)
    end
  end


  -- Determine tool mode: use manual override from opts, or auto-determine
  local current_model = opts.model or state.settings:get("model")
  local tool_mode
  if opts.tool_mode then
    -- Manual override from settings modal
    tool_mode = opts.tool_mode
  else
    -- Auto-determine based on settings
    tool_mode = tools.get_tool_mode({
      is_cli_model = false,  -- Already checked above
      web_search_enabled = web_search_enabled,
      rag_enabled = #rag_store_names > 0,
      model = current_model,
    })
  end

  -- Get enabled tools based on tool mode
  local enabled_tools = tools.get_enabled_tools({
    allow_write = state.settings:get("allow_write"),
    tool_mode = tool_mode,
  })

  -- Gemini file_search should be sent by itself. Combining it with function
  -- declarations can make RAG requests hang or return no content on newer models.
  if #rag_store_names > 0 then
    enabled_tools = {}
    tool_mode = "none"
  end

  -- Get MCP tools if tool_mode is not "none"
  local mcp_tool_list = {}
  if tool_mode ~= "none" then
    local enabled_mcp_names = opts.enabled_mcp_servers  -- nil = use all enabled servers
    local mcp_servers = mcp_tools.get_enabled_servers(
      state.settings:get_mcp_servers(),
      enabled_mcp_names
    )
    if #mcp_servers > 0 then
      mcp_tool_list = mcp_tools.fetch_mcp_tools(mcp_servers)
      -- Merge MCP tools with vault tools
      for _, mcp_tool in ipairs(mcp_tool_list) do
        table.insert(enabled_tools, mcp_tool)
      end
    end
  end

  -- Create MCP executor if we have MCP tools
  local current_mcp_executor = nil
  if #mcp_tool_list > 0 then
    current_mcp_executor = mcp_tools.create_executor(mcp_tool_list)
  end

  -- Build messages for API (copy to avoid mutation)
  local messages = {}
  for _, msg in ipairs(state.chat:get_messages()) do
    table.insert(messages, {
      role = msg.role,
      content = msg.content,
      timestamp = msg.timestamp,
    })
  end

  -- Debug: show message count in status
  state.chat:set_status("Sending " .. #messages .. " messages...")

  -- Get system prompt
  local system_prompt = state.settings:get("system_prompt")
  if not system_prompt or system_prompt == "" then
    system_prompt = DEFAULT_SYSTEM_PROMPT
  end

  -- Use array of RAG store names (or nil if empty)
  local rag_store_name = #rag_store_names > 0 and rag_store_names or nil

  local tools_used = {}
  local rag_sources = {}
  local web_search_used = false
  local mcp_apps = {}  -- MCP Apps with UI

  -- Use custom model if specified
  local client = state.gemini_client
  if opts.model and opts.model ~= state.settings:get("model") then
    client = gemini.new(state.settings:get("google_api_key"), opts.model)
  end

  client:chat_with_tools({
    messages = messages,
    tools = enabled_tools,
    system_prompt = system_prompt,
    rag_store_name = rag_store_name,
    web_search_enabled = web_search_enabled,
    debug_mode = state.settings:get("debug_mode"),
    execute_tool = function(tool_name, args)
      table.insert(tools_used, tool_name)
      state.chat:add_tool_call(tool_name, args)

      -- Check if this is an MCP tool
      if tool_name:match("^mcp_") and current_mcp_executor then
        local mcp_result = current_mcp_executor.execute(tool_name, args)
        if mcp_result.error then
          return { success = false, error = mcp_result.error }
        end
        -- Collect MCP App info if available
        if mcp_result.mcp_app then
          table.insert(mcp_apps, mcp_result.mcp_app)
        end
        return { success = true, result = mcp_result.result or "" }
      end

      -- Execute vault tool
      return state.executor:execute(tool_name, args)
    end,
    on_chunk = function(chunk)
      vim.schedule(function()
        if chunk.type == "text" then
          state.chat:set_status("Receiving response...")
          state.chat:update_streaming(chunk.text)
        elseif chunk.type == "tool_call" then
          state.chat:set_status("Calling tool: " .. chunk.name)
        elseif chunk.type == "tool_result" then
          state.chat:set_status("Tool completed: " .. chunk.name)
        elseif chunk.type == "rag_used" and chunk.sources then
          state.chat:set_status("Semantic search completed")
          for _, source in ipairs(chunk.sources) do
            table.insert(rag_sources, source)
          end
        elseif chunk.type == "web_search_used" then
          state.chat:set_status("Web search completed")
          web_search_used = true
        elseif chunk.type == "aborted" then
          state.chat:set_status("Stopped")
        end
      end)
    end,
    on_done = function(result)
      vim.schedule(function()
        -- Cleanup MCP executor
        if current_mcp_executor then
          current_mcp_executor.cleanup()
        end

        -- Handle aborted state
        if result.aborted then
          state.chat:end_streaming(nil, nil, nil, true)
          return
        end

        -- Store MCP apps for later use
        if #mcp_apps > 0 then
          state.last_mcp_apps = mcp_apps
          -- Auto-open MCP App if setting is enabled
          if state.settings:get("auto_open_mcp_app") then
            vim.defer_fn(function()
              M.open_mcp_app()
            end, 100)
          else
            vim.notify("MCP App available. Use :GeminiMcpAppOpen to view.", vim.log.levels.INFO)
          end
        end

        state.chat:end_streaming(
          #tools_used > 0 and tools_used or nil,
          #rag_sources > 0 and rag_sources or nil,
          result.web_search_used or web_search_used,
          nil,  -- aborted
          #mcp_apps > 0 and mcp_apps or nil
        )

        save_current_chat()
      end)
    end,
    on_error = function(err)
      vim.schedule(function()
        -- Cleanup MCP executor
        if current_mcp_executor then
          current_mcp_executor.cleanup()
        end

        state.chat:end_streaming()
        state.chat:show_error(tostring(err))
      end)
    end,
  })
end

---Handle message via CLI provider
---@param message string
---@param opts table
---@param model string
function M.handle_cli_message(message, opts, model)
  local provider_type = cli_provider.get_provider_type(model)
  local provider = state.cli_manager:get_provider(provider_type)

  if not provider then
    vim.notify("CLI provider not available: " .. model, vim.log.levels.ERROR)
    return
  end

  -- Check verification
  if not state.settings:is_cli_verified(provider_type) then
    local verify_cmd = "GeminiVerify" .. provider_type:gsub("%-cli", ""):gsub("^%l", string.upper) .. "Cli"
    vim.notify(
      "Please verify " .. provider.display_name .. " first with :" .. verify_cmd,
      vim.log.levels.WARN
    )
    return
  end

  state.chat:start_streaming()

  -- Get session ID for resumption (Claude/Codex only)
  local session_id = nil
  if provider.supports_session_resumption and state.current_chat_id then
    session_id = state.settings:get_cli_session(state.current_chat_id, provider_type)
  end

  -- Build messages
  local messages = {}
  for _, msg in ipairs(state.chat:get_messages()) do
    table.insert(messages, {
      role = msg.role,
      content = msg.content,
    })
  end

  -- Get system prompt
  local system_prompt = state.settings:get("system_prompt")
  if not system_prompt or system_prompt == "" then
    system_prompt = DEFAULT_SYSTEM_PROMPT
  end

  provider:chat_stream({
    messages = messages,
    system_prompt = system_prompt,
    working_directory = state.settings:get("workspace"),
    session_id = session_id,
    on_chunk = function(chunk)
      vim.schedule(function()
        if chunk.type == "text" then
          state.chat:set_status("Receiving response...")
          state.chat:update_streaming(chunk.content)
        elseif chunk.type == "session_id" then
          -- Store session ID for future resumption
          if state.current_chat_id then
            state.settings:set_cli_session(state.current_chat_id, provider_type, chunk.session_id)
          end
        elseif chunk.type == "error" then
          state.chat:show_error(chunk.error)
        end
      end)
    end,
    on_done = function(result)
      vim.schedule(function()
        state.chat:end_streaming(nil, nil, nil, result.aborted)

        -- Store session ID if provided
        if result.session_id and state.current_chat_id then
          state.settings:set_cli_session(state.current_chat_id, provider_type, result.session_id)
        end

        save_current_chat()
      end)
    end,
    on_error = function(err)
      vim.schedule(function()
        state.chat:end_streaming()
        state.chat:show_error(tostring(err))
      end)
    end,
  })
end

---Show chat history picker
function M.show_history()
  local chats = state.history_manager:list(50)

  if #chats == 0 then
    vim.notify("No chat history found in " .. state.settings:get("chats_folder"), vim.log.levels.INFO)
    return
  end

  -- Use vim.ui.select for simple picker
  local items = {}
  for _, chat in ipairs(chats) do
    local date = os.date("%Y-%m-%d %H:%M", (chat.updated_at or chat.created_at) / 1000)
    table.insert(items, {
      id = chat.id,
      display = string.format("[%s] %s", date, chat.title),
    })
  end

  vim.ui.select(items, {
    prompt = "Select chat:",
    format_item = function(item)
      return item.display
    end,
  }, function(selected)
    if selected then
      state.current_chat_id = selected.id
      local metadata, messages = state.history_manager:load(selected.id)
      if messages then
        if state.chat and state.chat:is_open() then
          state.chat:set_messages(messages)
        else
          M.open_chat()
          state.chat:set_messages(messages)
        end
      end
    end
  end)
end

---Show settings
function M.show_settings()
  local settings = state.settings:get_all()
  local search_type = state.settings:get_search_type()
  local bang_commands = state.settings:get_bang_commands()

  local api_plan = state.settings:get_api_plan()
  local lines = {
    "Gemini Helper Settings",
    "======================",
    "",
    string.format("API Key: %s", settings.google_api_key ~= "" and "****" .. settings.google_api_key:sub(-4) or "Not set"),
    string.format("API Plan: %s", api_plan),
    string.format("Model: %s", settings.model),
    string.format("Workspace: %s", settings.workspace),
    string.format("Allow Write: %s", settings.allow_write and "Yes" or "No"),
    "",
    "Search Settings:",
    string.format("  Current: %s", search_type == "websearch" and "Web Search" or (search_type == "semantic" and tostring(settings.search_setting) or "None")),
    "",
    string.format("Bang Commands: %d configured", #bang_commands),
  }

  for _, cmd in ipairs(bang_commands) do
    table.insert(lines, string.format("  !%s - %s", cmd.name, cmd.description or cmd.prompt_template:sub(1, 30)))
  end

  table.insert(lines, "")
  table.insert(lines, "Commands:")
  table.insert(lines, "  :GeminiSetApiKey <key> - Set API key")
  table.insert(lines, "  :GeminiSetApiPlan <paid|free> - Set API plan")
  table.insert(lines, "  :GeminiToggleWrite - Toggle write permissions")
  table.insert(lines, "  :GeminiWebSearch - Enable Web Search")
  table.insert(lines, "  :GeminiSearchNone - Disable search")
  table.insert(lines, "  :GeminiBangCommands - Show bang command picker")
  table.insert(lines, "  :GeminiAddBangCommand <name> <template> - Add command")
  table.insert(lines, "  :GeminiDebug - Toggle debug mode")

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = 60
  local height = #lines
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Settings ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })

  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

---Set API key
---@param api_key string
function M.set_api_key(api_key)
  state.settings:set("google_api_key", api_key)
  state.settings:save()

  -- Reinitialize client
  state.gemini_client = gemini.new(api_key, state.settings:get("model"))

  vim.notify("API key set successfully", vim.log.levels.INFO)
end

---Toggle write permissions
function M.toggle_write()
  local current = state.settings:get("allow_write")
  state.settings:set("allow_write", not current)
  state.settings:save()

  vim.notify(string.format("Write permissions: %s", not current and "Enabled" or "Disabled"), vim.log.levels.INFO)
end

---Get current state (for debugging)
function M.get_state()
  return state
end

---Get settings manager
function M.get_settings()
  return state.settings
end

---Get original buffer number (buffer active before chat was opened)
---@return number|nil
function M.get_original_bufnr()
  -- If original_bufnr is set and valid, return it
  if state.original_bufnr and vim.api.nvim_buf_is_valid(state.original_bufnr) then
    return state.original_bufnr
  end
  return nil
end

---Process command if first line starts with ! (bang command)
---@param message string
---@return string  expanded message
function M.process_bang_command(message)
  -- Split into lines and check first line only
  local lines = vim.split(message, "\n")
  local first_line = lines[1] or ""

  if not first_line:match("^!") then
    return message
  end

  -- Extract command name from first line
  local cmd_name = first_line:match("^!(%S+)")
  if not cmd_name then
    return message
  end

  -- Find command
  local command = state.settings:find_bang_command(cmd_name)
  if not command then
    return message
  end

  -- Get the rest of the message (selection content)
  local rest_content = ""
  if #lines > 1 then
    rest_content = table.concat(lines, "\n", 2)
  end

  -- Build final message: template + rest content
  local template = command.prompt_template
  if rest_content ~= "" then
    return template .. "\n" .. rest_content
  else
    return template
  end
end

---Show bang command picker
---@param selection string|nil  Optional selection to include
function M.show_bang_commands(selection)
  local commands = state.settings:get_bang_commands()

  if #commands == 0 then
    vim.notify("No bang commands configured. Use :GeminiAddBangCommand to add.", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, cmd in ipairs(commands) do
    table.insert(items, {
      name = cmd.name,
      description = cmd.description or "",
      command = cmd,
    })
  end

  vim.ui.select(items, {
    prompt = "Select command:",
    format_item = function(item)
      if item.description and item.description ~= "" then
        return "!" .. item.name .. " - " .. item.description
      end
      return "!" .. item.name
    end,
  }, function(selected)
    if selected then
      local template = selected.command.prompt_template
      local input_text
      if selection and selection ~= "" then
        -- Command + empty line + selection
        input_text = "!" .. selected.name .. "\n" .. selection
      else
        input_text = "!" .. selected.name
      end

      -- If chat is open, add to input
      if state.chat and state.chat:is_open() then
        state.chat:set_input(input_text)
      else
        -- Open chat and set input
        M.open_chat()
        vim.schedule(function()
          if state.chat then
            state.chat:set_input(input_text)
          end
        end)
      end
    end
  end)
end

---Add a new bang command
---@param opts table { name, prompt_template, description?, model?, search_setting? }
function M.add_bang_command(opts)
  if not opts.name or not opts.prompt_template then
    vim.notify("Bang command requires 'name' and 'prompt_template'", vim.log.levels.ERROR)
    return
  end

  state.settings:add_bang_command({
    name = opts.name,
    prompt_template = opts.prompt_template,
    description = opts.description,
    model = opts.model,
    search_setting = opts.search_setting,
  })
  state.settings:save()

  vim.notify("Bang command !" .. opts.name .. " added", vim.log.levels.INFO)
end

---Test API connection (non-streaming)
function M.test_api()
  if not state.gemini_client then
    vim.notify("Gemini client not initialized. Set API key first.", vim.log.levels.ERROR)
    return
  end

  vim.notify("Testing Gemini API...", vim.log.levels.INFO)

  local messages = {
    { role = "user", content = "Say hello in one word." }
  }

  local result, err = state.gemini_client:chat(messages, "Be brief.")

  if err then
    vim.notify("API Error: " .. err, vim.log.levels.ERROR)
  else
    vim.notify("API Response: " .. (result or "empty"), vim.log.levels.INFO)
  end
end

---Verify CLI provider installation
---@param provider_type string  "gemini-cli", "claude-cli", or "codex-cli"
function M.verify_cli(provider_type)
  vim.notify("Verifying " .. provider_type .. "...", vim.log.levels.INFO)

  local result
  if provider_type == "gemini-cli" then
    result = cli_provider.verify_gemini_cli()
  elseif provider_type == "claude-cli" then
    result = cli_provider.verify_claude_cli()
  elseif provider_type == "codex-cli" then
    result = cli_provider.verify_codex_cli()
  else
    vim.notify("Unknown CLI provider: " .. provider_type, vim.log.levels.ERROR)
    return
  end

  if result.success then
    state.settings:set_cli_verified(provider_type, true)
    state.settings:save()
    vim.notify(provider_type .. " verified successfully!", vim.log.levels.INFO)
  else
    vim.notify(
      provider_type .. " verification failed at " .. result.stage .. ": " .. (result.error or "unknown error"),
      vim.log.levels.ERROR
    )
  end
end

---Get available models (API based on plan + verified CLI)
---@return table[]  Array of model info tables
function M.get_available_models()
  local models = {}

  -- Get API models based on current plan
  if state.settings then
    local api_plan = state.settings:get_api_plan()
    for _, model_info in ipairs(gemini.get_models_for_plan(api_plan)) do
      table.insert(models, model_info)
    end

    -- Add verified CLI providers
    local verified_cli = state.settings:get_verified_cli_providers()
    for _, cli_name in ipairs(verified_cli) do
      -- Find CLI model info
      for _, cli_info in ipairs(gemini.CLI_MODEL_INFO) do
        if cli_info.name == cli_name then
          table.insert(models, cli_info)
          break
        end
      end
    end
  else
    -- Fallback to paid models if settings not initialized
    for _, model_info in ipairs(gemini.PAID_MODELS) do
      table.insert(models, model_info)
    end
  end

  return models
end

---Get CLI manager
---@return table|nil
function M.get_cli_manager()
  return state.cli_manager
end

-- ============================================================================
-- MCP Server Functions
-- ============================================================================

---Add an MCP server
---@param opts table { name, url, headers? }
function M.add_mcp_server(opts)
  if not opts.name or not opts.url then
    vim.notify("MCP server requires 'name' and 'url'", vim.log.levels.ERROR)
    return
  end

  state.settings:add_mcp_server({
    name = opts.name,
    url = opts.url,
    headers = opts.headers,
    enabled = true,
  })
  state.settings:save()

  vim.notify("MCP server '" .. opts.name .. "' added. Testing connection...", vim.log.levels.INFO)

  -- Automatically test the connection
  M.test_mcp_server(opts.name)
end

---Remove an MCP server
---@param name string
function M.remove_mcp_server(name)
  state.settings:remove_mcp_server(name)
  state.settings:save()
  -- Clear tools cache
  mcp_tools.clear_cache()
  vim.notify("MCP server '" .. name .. "' removed", vim.log.levels.INFO)
end

---Toggle MCP server enabled status
---@param name string
function M.toggle_mcp_server(name)
  local new_status = state.settings:toggle_mcp_server(name)
  state.settings:save()
  vim.notify(
    "MCP server '" .. name .. "': " .. (new_status and "enabled" or "disabled"),
    vim.log.levels.INFO
  )
end

---List MCP servers
function M.list_mcp_servers()
  local servers = state.settings:get_mcp_servers()

  if #servers == 0 then
    vim.notify("No MCP servers configured. Use :GeminiMcpAdd to add one.", vim.log.levels.INFO)
    return
  end

  local lines = { "MCP Servers:", "============", "" }

  for _, server in ipairs(servers) do
    local status = server.enabled and "[ON]" or "[OFF]"
    local tools_hint = ""
    if server.tool_hints and #server.tool_hints > 0 then
      tools_hint = " (" .. #server.tool_hints .. " tools)"
    end
    table.insert(lines, string.format("%s %s - %s%s", status, server.name, server.url, tools_hint))
  end

  table.insert(lines, "")
  table.insert(lines, "Commands:")
  table.insert(lines, "  :GeminiMcpAdd <name> <url> - Add server")
  table.insert(lines, "  :GeminiMcpTest <name> - Test connection")
  table.insert(lines, "  :GeminiMcpToggle <name> - Toggle enabled")
  table.insert(lines, "  :GeminiMcpRemove <name> - Remove server")

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = 60
  local height = #lines
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " MCP Servers ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })

  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

---Test MCP server connection
---@param name string
function M.test_mcp_server(name)
  local server = state.settings:find_mcp_server(name)
  if not server then
    vim.notify("MCP server '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  vim.notify("Testing MCP server '" .. name .. "'...", vim.log.levels.INFO)

  local success, err, tool_names = mcp_client.test_connection(server)

  if success then
    -- Update tool hints
    state.settings:update_mcp_server_tools(name, tool_names)
    state.settings:save()
    -- Clear tools cache to force refresh
    mcp_tools.clear_cache()

    local tools_msg = ""
    if tool_names and #tool_names > 0 then
      tools_msg = "\nTools: " .. table.concat(tool_names, ", ")
    end
    vim.notify("MCP server '" .. name .. "' connected successfully!" .. tools_msg, vim.log.levels.INFO)
  else
    vim.notify("MCP server '" .. name .. "' connection failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
  end
end

---Get MCP servers for chat settings
---@return table[]
function M.get_mcp_servers()
  return state.settings:get_mcp_servers()
end

---Get enabled MCP servers
---@return table[]
function M.get_enabled_mcp_servers()
  return state.settings:get_enabled_mcp_servers()
end

-- ============================================================================
-- MCP App Bridge Functions
-- ============================================================================

---Open MCP App in browser with WebSocket bridge
---@param app_index number|nil  Index of app to open (default: 1)
function M.open_mcp_app(app_index)
  app_index = app_index or 1

  if not state.last_mcp_apps or #state.last_mcp_apps == 0 then
    vim.notify("No MCP App available. Run a tool that returns UI first.", vim.log.levels.WARN)
    return
  end

  local app = state.last_mcp_apps[app_index]
  if not app then
    vim.notify("MCP App index " .. app_index .. " not found", vim.log.levels.ERROR)
    return
  end

  if not app.ui_resource then
    vim.notify("MCP App has no UI resource", vim.log.levels.ERROR)
    return
  end

  -- Create MCP client for tool calls from browser
  local mcp_client_for_app = mcp_client.new({
    name = "mcp_app_bridge",
    url = app.server_url,
  })

  local client_initialized = false

  -- Declare bridge first so the closure can capture it
  local bridge = nil
  local err

  -- Open the MCP App with WebSocket bridge
  bridge, err = mcp_app_bridge.open_mcp_app(
    app.ui_resource,
    app.server_url,
    {
      on_message = function(msg, ws_client)
        vim.schedule(function()
          -- Handle JSON-RPC 2.0 messages
          if msg.jsonrpc ~= "2.0" then
            return
          end

          -- Handle tools/call request
          if msg.method == "tools/call" and msg.id ~= nil then
            local params = msg.params or {}
            local tool_name = params.name
            local tool_args = params.arguments or {}
            local request_id = msg.id

            -- Initialize client if not done
            if not client_initialized then
              local _, init_err = mcp_client_for_app:initialize()
              if init_err then
                -- Send JSON-RPC error response
                if bridge then
                  bridge:send(ws_client, {
                    jsonrpc = "2.0",
                    id = request_id,
                    error = {
                      code = -32603,
                      message = "Failed to initialize MCP client: " .. init_err,
                    },
                  })
                end
                return
              end
              client_initialized = true
            end

            -- Call the tool
            local result, call_err = mcp_client_for_app:call_tool(tool_name, tool_args)

            if call_err then
              -- Send JSON-RPC error response
              if bridge then
                bridge:send(ws_client, {
                  jsonrpc = "2.0",
                  id = request_id,
                  error = {
                    code = -32000,
                    message = call_err,
                  },
                })
              end
            else
              -- Send JSON-RPC success response
              if bridge then
                bridge:send(ws_client, {
                  jsonrpc = "2.0",
                  id = request_id,
                  result = result,
                })
              end
            end
            return
          end

          -- Handle JSON-RPC notifications (no id)
          if msg.method and msg.id == nil then
            if state.settings:get("debug_mode") then
              vim.notify("MCP App notification: " .. msg.method, vim.log.levels.DEBUG)
            end
          end
        end)
      end,
    }
  )

  if not bridge then
    vim.notify("Failed to open MCP App: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end

  -- Store bridge and client for later cleanup
  table.insert(state.active_mcp_bridges, {
    bridge = bridge,
    client = mcp_client_for_app,
  })
end

---Close all active MCP App bridges
function M.close_mcp_app_bridges()
  local count = #state.active_mcp_bridges
  for _, item in ipairs(state.active_mcp_bridges) do
    -- Close bridge
    if item.bridge then
      pcall(function() item.bridge:close() end)
    elseif item.close then
      -- Old format (just bridge object)
      pcall(function() item:close() end)
    end
    -- Close MCP client
    if item.client then
      pcall(function() item.client:close() end)
    end
  end
  state.active_mcp_bridges = {}

  if count > 0 then
    vim.notify("Closed " .. count .. " MCP App bridge(s)", vim.log.levels.INFO)
  else
    vim.notify("No active MCP App bridges", vim.log.levels.INFO)
  end
end

---Send message to all connected MCP Apps
---@param message table
function M.send_to_mcp_apps(message)
  for _, item in ipairs(state.active_mcp_bridges) do
    local bridge = item.bridge or item
    if bridge.broadcast then
      bridge:broadcast({
        type = "to_app",
        data = message,
      })
    end
  end
end

---Get active MCP App bridges count
---@return number
function M.get_mcp_app_bridge_count()
  return #state.active_mcp_bridges
end

return M
