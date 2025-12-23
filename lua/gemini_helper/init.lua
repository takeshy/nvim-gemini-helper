-- Gemini Helper for Neovim
-- Main plugin entry point

local M = {}

-- Module imports
local gemini = require("gemini_helper.core.gemini")
local tools = require("gemini_helper.core.tools")
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
  notes_manager = nil,
  search_manager = nil,
  executor = nil,
  history_manager = nil,
  chat = nil,
  current_chat_id = nil,
  last_selection = "",  -- Cached selection for {selection} variable
  original_bufnr = nil,  -- Buffer that was active before opening chat
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
  if opts.rag_enabled ~= nil then
    state.settings:set("rag_enabled", opts.rag_enabled)
  end
  if opts.rag_store_name then
    state.settings:set("rag_store_name", opts.rag_store_name)
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

  -- Initialize tool executor
  state.executor = tool_executor.new(
    state.notes_manager,
    state.search_manager,
    state.settings:get_all()
  )

  -- Register commands
  M.register_commands()

  -- Create user commands
  vim.api.nvim_create_user_command("GeminiChat", function()
    M.open_chat()
  end, { desc = "Open Gemini chat" })

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

  vim.api.nvim_create_user_command("GeminiSlashCommands", function()
    M.show_slash_commands()
  end, { desc = "Show slash commands picker" })

  vim.api.nvim_create_user_command("GeminiAddSlashCommand", function(cmd_opts)
    local args = cmd_opts.args
    local name, template = args:match("^(%S+)%s+(.+)$")
    if name and template then
      M.add_slash_command({ name = name, prompt_template = template })
    else
      vim.notify("Usage: :GeminiAddSlashCommand <name> <template>", vim.log.levels.ERROR)
    end
  end, { nargs = "+", desc = "Add a slash command" })

  vim.api.nvim_create_user_command("GeminiWebSearch", function()
    state.settings:set("search_setting", "__websearch__")
    vim.notify("Web Search enabled for next message", vim.log.levels.INFO)
  end, { desc = "Enable Web Search for next message" })

  vim.api.nvim_create_user_command("GeminiSearchNone", function()
    state.settings:set("search_setting", nil)
    vim.notify("Search disabled", vim.log.levels.INFO)
  end, { desc = "Disable search" })

  vim.notify("Gemini Helper loaded", vim.log.levels.INFO)
end

---Register keymaps
function M.register_commands()
  -- Default keymaps (can be overridden in setup)
  vim.keymap.set("n", "<leader>gc", M.open_chat, { desc = "Open Gemini chat" })
  vim.keymap.set("n", "<leader>gn", M.new_chat, { desc = "New Gemini chat" })
  vim.keymap.set("n", "<leader>gh", M.show_history, { desc = "Gemini history" })
  vim.keymap.set("n", "<leader>gs", M.show_settings, { desc = "Gemini settings" })
  vim.keymap.set("n", "<leader>g/", M.show_slash_commands, { desc = "Gemini slash commands" })
  vim.keymap.set("v", "<leader>gc", function()
    M.capture_selection()
    M.open_chat()
  end, { desc = "Open Gemini chat with selection" })
end

---Open chat window
function M.open_chat()
  if not state.gemini_client then
    vim.notify("Please set your Google API key first with :GeminiSetApiKey", vim.log.levels.WARN)
    return
  end

  -- Save the original buffer before opening chat
  local current_buf = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(current_buf)
  -- Only save if it's a real file buffer (not chat window, empty, etc.)
  if bufname ~= "" and not bufname:match("^gemini_") then
    state.original_bufnr = current_buf
  end

  -- Capture selection before opening chat (in case we're in visual mode)
  M.capture_selection()

  -- Create chat UI if not exists
  if not state.chat or not state.chat:is_open() then
    state.chat = chat_ui.new({
      width = state.settings:get("chat_width"),
      height = state.settings:get("chat_height"),
      position = state.settings:get("chat_position"),
      model_name = state.settings:get("model"),
      on_send = function(message)
        -- Process slash command if present
        local expanded, cmd_opts = M.process_slash_command(message)
        M.handle_message(expanded, cmd_opts)
      end,
      on_stop = function()
        if state.gemini_client then
          state.gemini_client:abort()
          vim.notify("Generation stopped", vim.log.levels.INFO)
        end
      end,
    })
    state.chat:open()

    -- Load last chat if exists
    if state.current_chat_id then
      local metadata, messages = state.history_manager:load(state.current_chat_id)
      if messages then
        state.chat:set_messages(messages)
      end
    end
  end
end

---Start new chat
function M.new_chat()
  -- Save current chat if exists
  if state.current_chat_id and state.chat then
    local messages = state.chat:get_messages()
    if #messages > 0 then
      state.history_manager:save(state.current_chat_id, messages)
    end
  end

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
  if not state.gemini_client then
    vim.notify("Gemini client not initialized", vim.log.levels.ERROR)
    return
  end

  opts = opts or {}

  state.chat:start_streaming()

  -- Determine search settings
  local search_setting = opts.search_setting or state.settings:get("search_setting")
  local web_search_enabled = search_setting == "__websearch__"

  -- Get enabled tools (empty if rag_only mode or web_search mode)
  local enabled_tools = {}
  if not state.settings:get("rag_only") and not web_search_enabled then
    enabled_tools = tools.get_enabled_tools({
      allow_write = state.settings:get("allow_write"),
    })
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

  -- Get RAG store name if configured and not using web search
  local rag_store_name = nil
  if not web_search_enabled then
    if search_setting and search_setting ~= "" and search_setting ~= "__websearch__" then
      -- Use search_setting as semantic search store name
      rag_store_name = search_setting
      if not rag_store_name:match("^fileSearchStores/") then
        rag_store_name = "fileSearchStores/" .. rag_store_name
      end
    elseif state.settings:is_rag_configured() then
      rag_store_name = state.settings:get_rag_store_name()
    end
  end

  local tools_used = {}
  local rag_sources = {}
  local web_search_used = false

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
    execute_tool = function(tool_name, args)
      table.insert(tools_used, tool_name)
      state.chat:add_tool_call(tool_name, args)
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
        -- Handle aborted state
        if result.aborted then
          state.chat:end_streaming(nil, nil, nil, true)
          return
        end

        state.chat:end_streaming(
          #tools_used > 0 and tools_used or nil,
          #rag_sources > 0 and rag_sources or nil,
          result.web_search_used or web_search_used
        )

        -- Save chat
        if state.current_chat_id then
          local all_messages = state.chat:get_messages()
          state.history_manager:save(state.current_chat_id, all_messages)
        end
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
    vim.notify("No chat history found", vim.log.levels.INFO)
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
  local slash_commands = state.settings:get_slash_commands()

  local lines = {
    "Gemini Helper Settings",
    "======================",
    "",
    string.format("API Key: %s", settings.google_api_key ~= "" and "****" .. settings.google_api_key:sub(-4) or "Not set"),
    string.format("Model: %s", settings.model),
    string.format("Workspace: %s", settings.workspace),
    string.format("Allow Write: %s", settings.allow_write and "Yes" or "No"),
    "",
    "Search Settings:",
    string.format("  Current: %s", search_type == "websearch" and "Web Search" or (search_type == "semantic" and settings.search_setting or "None")),
    string.format("  RAG Enabled: %s", settings.rag_enabled and "Yes" or "No"),
    string.format("  RAG Store: %s", settings.rag_store_name or "Not configured"),
    "",
    string.format("Slash Commands: %d configured", #slash_commands),
  }

  for _, cmd in ipairs(slash_commands) do
    table.insert(lines, string.format("  /%s - %s", cmd.name, cmd.description or cmd.prompt_template:sub(1, 30)))
  end

  table.insert(lines, "")
  table.insert(lines, "Commands:")
  table.insert(lines, "  :GeminiSetApiKey <key> - Set API key")
  table.insert(lines, "  :GeminiToggleWrite - Toggle write permissions")
  table.insert(lines, "  :GeminiWebSearch - Enable Web Search")
  table.insert(lines, "  :GeminiSearchNone - Disable search")
  table.insert(lines, "  :GeminiSlashCommands - Show slash command picker")
  table.insert(lines, "  :GeminiAddSlashCommand <name> <template> - Add command")

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

---Capture current visual selection
---@return string
function M.capture_selection()
  -- Get the current visual selection
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    -- In visual mode, get selection
    vim.cmd('normal! "vy')
    local selection = vim.fn.getreg("v")
    if selection and selection ~= "" then
      state.last_selection = selection
    end
  end
  return state.last_selection
end

---Get the last captured selection
---@return string
function M.get_last_selection()
  return state.last_selection
end

---Clear the cached selection
function M.clear_last_selection()
  state.last_selection = ""
end

---Expand slash command template
---@param template string
---@return string
function M.expand_template(template)
  local result = template

  -- Expand {selection} variable
  result = result:gsub("{selection}", state.last_selection or "")

  -- Expand {file} variable - current file name
  local current_file = vim.fn.expand("%:t")
  result = result:gsub("{file}", current_file or "")

  -- Expand {filepath} variable - full file path
  local file_path = vim.fn.expand("%:p")
  result = result:gsub("{filepath}", file_path or "")

  -- Expand {line} variable - current line content
  local current_line = vim.api.nvim_get_current_line()
  result = result:gsub("{line}", current_line or "")

  return result
end

---Process slash command if message starts with /
---@param message string
---@return string, table|nil  (expanded message, command opts or nil)
function M.process_slash_command(message)
  if not message:match("^/") then
    return message, nil
  end

  -- Extract command name
  local cmd_name = message:match("^/(%S+)")
  if not cmd_name then
    return message, nil
  end

  -- Find command
  local command = state.settings:find_slash_command(cmd_name)
  if not command then
    return message, nil
  end

  -- Expand template
  local expanded = M.expand_template(command.prompt_template)

  -- Build options
  local opts = {}
  if command.model then
    opts.model = command.model
  end
  if command.search_setting then
    opts.search_setting = command.search_setting
  end

  return expanded, opts
end

---Show slash command picker
function M.show_slash_commands()
  local commands = state.settings:get_slash_commands()

  if #commands == 0 then
    vim.notify("No slash commands configured. Add them in settings.", vim.log.levels.INFO)
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
    prompt = "Select slash command:",
    format_item = function(item)
      if item.description and item.description ~= "" then
        return "/" .. item.name .. " - " .. item.description
      end
      return "/" .. item.name
    end,
  }, function(selected)
    if selected then
      -- Capture selection before processing
      M.capture_selection()

      local expanded = M.expand_template(selected.command.prompt_template)

      -- If chat is open, add to input
      if state.chat and state.chat:is_open() then
        state.chat:set_input(expanded)
      else
        -- Open chat and send message
        M.open_chat()
        vim.schedule(function()
          if state.chat then
            state.chat:set_input(expanded)
          end
        end)
      end
    end
  end)
end

---Add a new slash command
---@param opts table { name, prompt_template, model?, description?, search_setting? }
function M.add_slash_command(opts)
  if not opts.name or not opts.prompt_template then
    vim.notify("Slash command requires 'name' and 'prompt_template'", vim.log.levels.ERROR)
    return
  end

  state.settings:add_slash_command({
    name = opts.name,
    prompt_template = opts.prompt_template,
    model = opts.model,
    description = opts.description,
    search_setting = opts.search_setting,
  })
  state.settings:save()

  vim.notify("Slash command /" .. opts.name .. " added", vim.log.levels.INFO)
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

return M
