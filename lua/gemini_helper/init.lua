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

  vim.notify("Gemini Helper loaded", vim.log.levels.INFO)
end

---Register keymaps
function M.register_commands()
  -- Default keymaps (can be overridden in setup)
  vim.keymap.set("n", "<leader>gc", M.open_chat, { desc = "Open Gemini chat" })
  vim.keymap.set("n", "<leader>gn", M.new_chat, { desc = "New Gemini chat" })
  vim.keymap.set("n", "<leader>gh", M.show_history, { desc = "Gemini history" })
  vim.keymap.set("n", "<leader>gs", M.show_settings, { desc = "Gemini settings" })
end

---Open chat window
function M.open_chat()
  if not state.gemini_client then
    vim.notify("Please set your Google API key first with :GeminiSetApiKey", vim.log.levels.WARN)
    return
  end

  -- Create chat UI if not exists
  if not state.chat or not state.chat:is_open() then
    state.chat = chat_ui.new({
      width = state.settings:get("chat_width"),
      height = state.settings:get("chat_height"),
      position = state.settings:get("chat_position"),
      model_name = state.settings:get("model"),
      on_send = function(message)
        M.handle_message(message)
      end,
      on_stop = function()
        -- TODO: Implement abort
        vim.notify("Stopping not yet implemented", vim.log.levels.INFO)
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
function M.handle_message(message)
  if not state.gemini_client then
    vim.notify("Gemini client not initialized", vim.log.levels.ERROR)
    return
  end

  state.chat:start_streaming()

  -- Get enabled tools (empty if rag_only mode)
  local enabled_tools = {}
  if not state.settings:get("rag_only") then
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

  -- Get RAG store name if configured
  local rag_store_name = nil
  if state.settings:is_rag_configured() then
    rag_store_name = state.settings:get_rag_store_name()
  end

  local tools_used = {}
  local rag_sources = {}

  state.gemini_client:chat_with_tools({
    messages = messages,
    tools = enabled_tools,
    system_prompt = system_prompt,
    rag_store_name = rag_store_name,
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
          state.chat:set_status("RAG search completed")
          for _, source in ipairs(chunk.sources) do
            table.insert(rag_sources, source)
          end
        end
      end)
    end,
    on_done = function(result)
      vim.schedule(function()
        state.chat:end_streaming(
          #tools_used > 0 and tools_used or nil,
          #rag_sources > 0 and rag_sources or nil
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

  local lines = {
    "Gemini Helper Settings",
    "======================",
    "",
    string.format("API Key: %s", settings.google_api_key ~= "" and "****" .. settings.google_api_key:sub(-4) or "Not set"),
    string.format("Model: %s", settings.model),
    string.format("Workspace: %s", settings.workspace),
    string.format("Allow Write: %s", settings.allow_write and "Yes" or "No"),
    string.format("RAG Enabled: %s", settings.rag_enabled and "Yes" or "No"),
    string.format("RAG Store: %s", settings.rag_store_name or "Not configured"),
    "",
    "Commands:",
    "  :GeminiSetApiKey <key> - Set API key",
    "  :GeminiToggleWrite - Toggle write permissions",
  }

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
