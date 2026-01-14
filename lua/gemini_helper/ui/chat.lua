-- Chat UI for Neovim
-- Provides floating window interface for Gemini chat

local M = {}

local api = vim.api

---@class ChatUI
---@field main_buf number
---@field main_win number
---@field input_buf number
---@field input_win number
---@field settings_buf number
---@field settings_win number
---@field messages table[]
---@field on_send function
---@field on_stop function
---@field is_streaming boolean
---@field current_response string
---@field status string
---@field tool_calls table[]
---@field model_name string
---@field pending_settings table
local ChatUI = {}
ChatUI.__index = ChatUI

-- Highlight groups
local function setup_highlights()
  vim.cmd([[
    highlight default GeminiUser guifg=#61afef gui=bold
    highlight default GeminiAssistant guifg=#98c379 gui=bold
    highlight default GeminiTool guifg=#e5c07b gui=italic
    highlight default GeminiError guifg=#e06c75 gui=bold
    highlight default GeminiRAG guifg=#c678dd gui=italic
    highlight default GeminiWebSearch guifg=#61afef gui=italic
    highlight default GeminiDivider guifg=#5c6370
    highlight default GeminiStatus guifg=#56b6c2 gui=italic
    highlight default GeminiSpinner guifg=#e5c07b gui=bold
  ]])
end

-- Spinner animation
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 1

---Create a new chat UI
---@param opts table
---@return ChatUI
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, ChatUI)
  self.messages = {}
  self.on_send = opts.on_send
  self.on_stop = opts.on_stop
  self.on_get_bang_commands = opts.on_get_bang_commands  -- Callback to get bang commands
  self.on_get_files = opts.on_get_files  -- Callback to get file list
  self.on_get_default_settings = opts.on_get_default_settings  -- Callback to get default settings
  self.on_get_original_win = opts.on_get_original_win  -- Callback to get original window
  self.on_fetch_rag_stores = opts.on_fetch_rag_stores  -- Callback to fetch RAG stores
  self.available_models = opts.available_models or {}  -- Available model options
  self.pending_settings = nil  -- Temporary settings override { model?, search_setting? }
  self.is_streaming = false
  self.current_response = ""
  self.status = ""
  self.tool_calls = {}
  self.width = opts.width or 50
  self.height = opts.height or 20
  self.position = opts.position or "right" -- "right", "bottom", "center"
  self.spinner_timer = nil
  self.model_name = opts.model_name or "Gemini"
  self.input_height = 2  -- Default input height
  return self
end

---Calculate window dimensions
---@param self ChatUI
---@return table, table, table
function ChatUI:calculate_dimensions()
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local width = math.min(self.width, editor_width - 4)

  -- Full height (minus statusline and cmdline)
  local height = editor_height - 3

  local col, row

  if self.position == "bottom" then
    -- Position at bottom
    height = math.min(self.height, editor_height - 4)
    col = math.floor((editor_width - width) / 2)
    row = editor_height - height - 2
  elseif self.position == "center" then
    -- Position at center
    height = math.min(self.height, editor_height - 4)
    col = math.floor((editor_width - width) / 2)
    row = math.floor((editor_height - height) / 2)
  else
    -- Default: position at right edge, full height
    col = editor_width - width - 1
    row = 0
  end

  local input_height = self.input_height or 2  -- Default 2 lines, can grow
  local settings_height = 1  -- Settings bar is 1 line

  local main_config = {
    relative = "editor",
    width = width,
    height = height - input_height - settings_height - 3, -- Leave room for input + settings
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Gemini Chat ",
    title_pos = "center",
  }

  local input_config = {
    relative = "editor",
    width = width,
    height = input_height,
    col = col,
    row = row + height - input_height - settings_height - 2,
    style = "minimal",
    border = "rounded",
    title = " [N] Enter: send | [I] C-s: send | ?: settings | q: close ",
    title_pos = "center",
  }

  local settings_config = {
    relative = "editor",
    width = width,
    height = settings_height,
    col = col,
    row = row + height - settings_height - 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
  }

  return main_config, input_config, settings_config
end

---Resize input window based on content
---@param self ChatUI
function ChatUI:resize_input()
  if not self.input_buf or not api.nvim_buf_is_valid(self.input_buf) then
    return
  end

  local line_count = api.nvim_buf_line_count(self.input_buf)
  local new_height = math.max(2, math.min(line_count, 10))  -- Min 2, max 10

  if new_height ~= self.input_height then
    self.input_height = new_height

    -- Recalculate and resize windows
    local main_config, input_config, settings_config = self:calculate_dimensions()

    if self.main_win and api.nvim_win_is_valid(self.main_win) then
      api.nvim_win_set_config(self.main_win, {
        relative = "editor",
        width = main_config.width,
        height = main_config.height,
        row = main_config.row,
        col = main_config.col,
      })
    end

    if self.input_win and api.nvim_win_is_valid(self.input_win) then
      api.nvim_win_set_config(self.input_win, {
        relative = "editor",
        width = input_config.width,
        height = input_config.height,
        row = input_config.row,
        col = input_config.col,
      })
    end

    if self.settings_win and api.nvim_win_is_valid(self.settings_win) then
      api.nvim_win_set_config(self.settings_win, {
        relative = "editor",
        width = settings_config.width,
        height = settings_config.height,
        row = settings_config.row,
        col = settings_config.col,
      })
    end
  end
end

---Open the chat window
---@param self ChatUI
function ChatUI:open()
  setup_highlights()

  local main_config, input_config, settings_config = self:calculate_dimensions()

  -- Create main buffer
  self.main_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(self.main_buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.main_buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(self.main_buf, "filetype", "markdown")

  -- Create input buffer
  self.input_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(self.input_buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.input_buf, "bufhidden", "wipe")

  -- Create settings buffer
  self.settings_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(self.settings_buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.settings_buf, "bufhidden", "wipe")

  -- Open windows
  self.main_win = api.nvim_open_win(self.main_buf, false, main_config)
  self.input_win = api.nvim_open_win(self.input_buf, true, input_config)
  self.settings_win = api.nvim_open_win(self.settings_buf, false, settings_config)

  -- Set window options
  api.nvim_win_set_option(self.main_win, "wrap", true)
  api.nvim_win_set_option(self.main_win, "linebreak", true)
  api.nvim_win_set_option(self.main_win, "cursorline", false)

  api.nvim_win_set_option(self.input_win, "wrap", true)

  -- Render initial settings bar
  self:render_settings_bar()

  -- Set keymaps for input buffer
  local input_opts = { noremap = true, silent = true, buffer = self.input_buf }

  -- Insert mode Enter: handle completion popup and bang commands, otherwise newline
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      -- Check if an item is already selected
      local info = vim.fn.complete_info()
      local selected = info.selected or -1
      vim.schedule(function()
        self:replace_command_with_template()
      end)
      if selected >= 0 then
        -- Item already selected (e.g., after Tab), just confirm
        return vim.api.nvim_replace_termcodes("<C-y>", true, false, true)
      else
        -- No item selected, select first and confirm
        return vim.api.nvim_replace_termcodes("<C-n><C-y>", true, false, true)
      end
    end

    -- Check if we're typing a command on line 1
    local cursor = api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local line = api.nvim_get_current_line()

    if row == 1 and line:match("^!%S+$") and self.on_get_bang_commands then
      local cmd_name = line:match("^!(%S+)$")
      local commands = self.on_get_bang_commands()
      -- Find exact match or single partial match
      local exact_match = nil
      local partial_matches = {}
      for _, cmd in ipairs(commands) do
        if cmd.name == cmd_name then
          exact_match = cmd
          break
        elseif cmd.name:find("^" .. vim.pesc(cmd_name)) then
          table.insert(partial_matches, cmd)
        end
      end

      local matched_cmd = exact_match or (#partial_matches == 1 and partial_matches[1] or nil)
      if matched_cmd then
        -- Apply command settings and replace with template (deferred)
        vim.schedule(function()
          local template = matched_cmd.prompt_template or ""
          api.nvim_buf_set_lines(self.input_buf, 0, 1, false, {template})
          api.nvim_win_set_cursor(0, { 1, #template })
          self:apply_command_settings(matched_cmd)
        end)
        return ""
      end
    end

    -- Default: insert newline
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end, { noremap = true, silent = true, buffer = self.input_buf, expr = true })

  -- Normal mode Enter: send message
  vim.keymap.set("n", "<CR>", function()
    self:send_message()
  end, input_opts)

  -- Tab to select next completion item
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return vim.api.nvim_replace_termcodes("<C-n>", true, false, true)
    else
      return vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
    end
  end, { noremap = true, silent = true, buffer = self.input_buf, expr = true })

  -- Shift+Tab to select previous completion item
  vim.keymap.set("i", "<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return vim.api.nvim_replace_termcodes("<C-p>", true, false, true)
    else
      return vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true)
    end
  end, { noremap = true, silent = true, buffer = self.input_buf, expr = true })

  -- Ctrl+s also sends (alternative for insert mode)
  vim.keymap.set({ "i", "n" }, "<C-s>", function()
    self:send_message()
  end, input_opts)

  -- Stop generation with Ctrl+c
  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    if self.is_streaming and self.on_stop then
      self.on_stop()
    end
  end, input_opts)

  -- Close with q (normal mode) or Ctrl+q (insert mode)
  vim.keymap.set("n", "q", function()
    self:close()
  end, input_opts)

  vim.keymap.set("i", "<C-q>", function()
    self:close()
  end, input_opts)

  vim.keymap.set("n", "<Esc>", function()
    self:close()
  end, input_opts)

  -- Toggle focus between chat input and original buffer with Ctrl+\
  vim.keymap.set({ "i", "n" }, "<C-\\>", function()
    if self.on_get_original_win then
      local orig_win = self.on_get_original_win()
      if orig_win and api.nvim_win_is_valid(orig_win) then
        api.nvim_set_current_win(orig_win)
      end
    end
  end, input_opts)

  -- Page scroll with Ctrl+u/d
  vim.keymap.set({ "i", "n" }, "<C-u>", function()
    if self.main_win and api.nvim_win_is_valid(self.main_win) then
      local win_height = api.nvim_win_get_height(self.main_win)
      local scroll_amount = math.floor(win_height / 2)
      vim.fn.win_execute(self.main_win, "normal! " .. scroll_amount .. "k")
    end
  end, input_opts)

  vim.keymap.set({ "i", "n" }, "<C-d>", function()
    if self.main_win and api.nvim_win_is_valid(self.main_win) then
      local win_height = api.nvim_win_get_height(self.main_win)
      local scroll_amount = math.floor(win_height / 2)
      vim.fn.win_execute(self.main_win, "normal! " .. scroll_amount .. "j")
    end
  end, input_opts)

  -- Set keymaps for main buffer (message display)
  local main_opts = { noremap = true, silent = true, buffer = self.main_buf }

  vim.keymap.set("n", "q", function()
    self:close()
  end, main_opts)

  vim.keymap.set("n", "<Esc>", function()
    self:close()
  end, main_opts)

  vim.keymap.set({ "i", "n" }, "<C-c>", function()
    if self.is_streaming and self.on_stop then
      self.on_stop()
    end
  end, main_opts)

  -- Toggle focus from main buffer to original buffer with Ctrl+\
  vim.keymap.set({ "i", "n" }, "<C-\\>", function()
    if self.on_get_original_win then
      local orig_win = self.on_get_original_win()
      if orig_win and api.nvim_win_is_valid(orig_win) then
        api.nvim_set_current_win(orig_win)
      end
    end
  end, main_opts)

  -- Disable other completion plugins for this buffer
  vim.api.nvim_buf_set_option(self.input_buf, "omnifunc", "")
  vim.api.nvim_buf_set_option(self.input_buf, "completefunc", "")

  -- Command completion with ! (insert ! and show completions)
  vim.keymap.set("i", "!", function()
    local cursor = api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local col = cursor[2]
    local line = api.nvim_get_current_line()
    local before_cursor = line:sub(1, col)

    -- Only show completion if ! is at the beginning of line 1
    if row == 1 and before_cursor == "" and self.on_get_bang_commands then
      local commands = self.on_get_bang_commands()
      if commands and #commands == 1 then
        -- Single command: replace with prompt_template and apply settings
        local cmd = commands[1]
        local template = cmd.prompt_template or ""
        -- Apply command settings to pending_settings
        self:apply_command_settings(cmd)
        -- Set first line to template
        api.nvim_buf_set_lines(self.input_buf, 0, 1, false, {template})
        -- Move cursor to end of first line
        api.nvim_win_set_cursor(0, { 1, #template })
        return
      elseif commands and #commands > 1 then
        -- Multiple commands: insert ! and show completion
        api.nvim_buf_set_lines(self.input_buf, 0, 1, false, {"!"})
        api.nvim_win_set_cursor(0, { 1, 1 })
        vim.schedule(function()
          self:show_bang_completions()
        end)
        return
      end
    end

    -- Default: just insert !
    vim.api.nvim_feedkeys("!", "n", false)
  end, input_opts)

  -- Settings modal with ? (at beginning of line 1)
  vim.keymap.set("i", "?", function()
    local cursor = api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local col = cursor[2]
    local line = api.nvim_get_current_line()
    local before_cursor = line:sub(1, col)

    -- Only show settings if ? is at the beginning of line 1
    if row == 1 and before_cursor == "" then
      self:show_settings_modal()
      return
    end

    -- Default: just insert ?
    vim.api.nvim_feedkeys("?", "n", false)
  end, input_opts)

  -- File path completion with @
  vim.keymap.set("i", "@", function()
    -- Insert the @
    api.nvim_feedkeys("@", "n", false)

    vim.schedule(function()
      self:show_file_completions()
    end)
  end, input_opts)

  -- Auto-resize input when content changes
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = self.input_buf,
    callback = function()
      self:resize_input()
    end,
  })

  -- Start in insert mode
  vim.cmd("startinsert")

  -- Render initial state
  self:render()
end

---Close the chat window
---@param self ChatUI
function ChatUI:close()
  if self.main_win and api.nvim_win_is_valid(self.main_win) then
    api.nvim_win_close(self.main_win, true)
  end
  if self.input_win and api.nvim_win_is_valid(self.input_win) then
    api.nvim_win_close(self.input_win, true)
  end
  if self.settings_win and api.nvim_win_is_valid(self.settings_win) then
    api.nvim_win_close(self.settings_win, true)
  end
  self.main_win = nil
  self.input_win = nil
  self.settings_win = nil
  -- Keep pending_settings so they persist when reopening
end

---Check if window is open
---@param self ChatUI
---@return boolean
function ChatUI:is_open()
  return self.main_win and api.nvim_win_is_valid(self.main_win)
end

---Focus the input window
---@param self ChatUI
function ChatUI:focus_input()
  if self.input_win and api.nvim_win_is_valid(self.input_win) then
    api.nvim_set_current_win(self.input_win)
    vim.cmd("startinsert")
  end
end

---Send message from input
---@param self ChatUI
function ChatUI:send_message()
  if self.is_streaming then
    vim.notify("Still streaming, please wait...", vim.log.levels.WARN)
    return
  end

  local lines = api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

  if message == "" then
    return
  end

  -- Clear input and reset height (set to 0 to force resize detection)
  api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
  self.input_height = 0
  self:resize_input()

  -- Add user message
  self:add_message({
    role = "user",
    content = message,
    timestamp = os.time() * 1000,
  })

  -- Call send handler with pending settings (keep settings for next message)
  if self.on_send then
    -- Copy pending_settings to avoid mutation issues
    local settings_copy = nil
    if self.pending_settings then
      settings_copy = vim.deepcopy(self.pending_settings)
    end
    self.on_send(message, settings_copy)
  end

  -- Re-render settings bar to confirm settings are still active
  self:render_settings_bar()
end

---Add a message to the chat
---@param self ChatUI
---@param message table
function ChatUI:add_message(message)
  table.insert(self.messages, message)
  self:render()
end

---Update the last assistant message (for streaming)
---@param self ChatUI
---@param text string
function ChatUI:update_streaming(text)
  self.current_response = self.current_response .. text
  self:render()
end

---Start streaming response
---@param self ChatUI
function ChatUI:start_streaming()
  self.is_streaming = true
  self.current_response = ""

  -- Set status based on current model
  local model_name = self:get_model_display_name()
  self.status = "Connecting to " .. model_name .. "..."

  self.tool_calls = {}
  self:render()

  -- Start spinner animation
  self:start_spinner()
end

---Start spinner animation
---@param self ChatUI
function ChatUI:start_spinner()
  if self.spinner_timer then
    return
  end

  self.spinner_timer = vim.loop.new_timer()
  self.spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if self.is_streaming and self:is_open() then
      spinner_index = (spinner_index % #spinner_frames) + 1
      self:render()
    end
  end))
end

---Stop spinner animation
---@param self ChatUI
function ChatUI:stop_spinner()
  if self.spinner_timer then
    self.spinner_timer:stop()
    self.spinner_timer:close()
    self.spinner_timer = nil
  end
end

---Update status
---@param self ChatUI
---@param status string
function ChatUI:set_status(status)
  self.status = status
  self:render()
end

---End streaming response
---@param self ChatUI
---@param tools_used string[]|nil
---@param rag_sources string[]|nil
---@param web_search_used boolean|nil
---@param aborted boolean|nil
function ChatUI:end_streaming(tools_used, rag_sources, web_search_used, aborted)
  self.is_streaming = false
  self.status = ""
  self:stop_spinner()

  local response_content = nil

  if self.current_response ~= "" then
    local content = self.current_response
    if aborted then
      content = content .. "\n\n*(Generation stopped)*"
    end
    response_content = content
    self:add_message({
      role = "assistant",
      content = content,
      timestamp = os.time() * 1000,
      tools_used = tools_used,
      rag_sources = rag_sources,
      web_search_used = web_search_used,
    })
  elseif aborted then
    -- Show stopped message even if no response yet
    self:add_message({
      role = "assistant",
      content = "*(Generation stopped)*",
      timestamp = os.time() * 1000,
    })
  end

  -- Auto copy response to * register if enabled
  if response_content and not aborted then
    local settings = {}
    if self.on_get_default_settings then
      settings = self.on_get_default_settings()
    end
    if settings.auto_copy_response ~= false then
      vim.fn.setreg('*', response_content)
    end
  end

  self.current_response = ""
  self.tool_calls = {}
end

---Add tool call indicator
---@param self ChatUI
---@param tool_name string
---@param args table
function ChatUI:add_tool_call(tool_name, args)
  table.insert(self.tool_calls, { name = tool_name, args = args })
  self.status = "Calling tool: " .. tool_name
  self:render()
end

---Get display name for the current model
---@param self ChatUI
---@return string
function ChatUI:get_model_display_name()
  local settings = self:get_effective_settings()
  local model = settings.model

  -- CLI models
  if model == "claude-cli" then
    return "Claude"
  elseif model == "codex-cli" then
    return "Codex"
  elseif model == "gemini-cli" then
    return "Gemini CLI"
  end

  -- API models - find display name from available_models
  for _, model_info in ipairs(self.available_models or {}) do
    if type(model_info) == "table" and model_info.name == model then
      return model_info.display_name or model_info.name
    end
  end

  -- Fallback: format model name nicely
  if model then
    -- "gemini-3-flash-preview" -> "Gemini 3 Flash"
    local name = model:gsub("^gemini%-", "Gemini "):gsub("%-preview$", ""):gsub("%-", " ")
    return name:gsub("(%a)([%w]*)", function(first, rest)
      return first:upper() .. rest
    end)
  end

  return "Gemini"
end

---Render the chat
---@param self ChatUI
function ChatUI:render()
  if not self.main_buf or not api.nvim_buf_is_valid(self.main_buf) then
    return
  end

  local lines = {}
  local highlights = {}

  -- Get display name for assistant messages
  local assistant_name = self:get_model_display_name()

  for _, msg in ipairs(self.messages) do
    local role_name = msg.role == "user" and "You" or assistant_name
    local hl_group = msg.role == "user" and "GeminiUser" or "GeminiAssistant"

    -- Role header
    local header_line = #lines
    table.insert(lines, string.format("### %s", role_name))
    table.insert(highlights, { line = header_line, col = 0, end_col = -1, hl = hl_group })

    -- Tools used
    if msg.tools_used and #msg.tools_used > 0 then
      local tools_line = #lines
      table.insert(lines, "  [Tools: " .. table.concat(msg.tools_used, ", ") .. "]")
      table.insert(highlights, { line = tools_line, col = 0, end_col = -1, hl = "GeminiTool" })
    end

    -- RAG sources
    if msg.rag_sources and #msg.rag_sources > 0 then
      local rag_line = #lines
      table.insert(lines, "  [Semantic Search: " .. table.concat(msg.rag_sources, ", ") .. "]")
      table.insert(highlights, { line = rag_line, col = 0, end_col = -1, hl = "GeminiRAG" })
    end

    -- Web Search indicator
    if msg.web_search_used then
      local ws_line = #lines
      table.insert(lines, "  [Web Search]")
      table.insert(highlights, { line = ws_line, col = 0, end_col = -1, hl = "GeminiWebSearch" })
    end

    table.insert(lines, "")

    -- Content
    for line in msg.content:gmatch("[^\n]*") do
      table.insert(lines, line)
    end

    table.insert(lines, "")

    -- Divider
    local div_line = #lines
    table.insert(lines, string.rep("-", 40))
    table.insert(highlights, { line = div_line, col = 0, end_col = -1, hl = "GeminiDivider" })
    table.insert(lines, "")
  end

  -- Add streaming response
  if self.is_streaming then
    local header_line = #lines
    local spinner = spinner_frames[spinner_index]
    table.insert(lines, string.format("### %s %s", assistant_name, spinner))
    table.insert(highlights, { line = header_line, col = 0, end_col = -1, hl = "GeminiAssistant" })

    -- Show status
    if self.status and self.status ~= "" then
      local status_line = #lines
      table.insert(lines, "  [" .. self.status .. "]")
      table.insert(highlights, { line = status_line, col = 0, end_col = -1, hl = "GeminiStatus" })
    end

    -- Show tool calls in progress
    if #self.tool_calls > 0 then
      for _, tc in ipairs(self.tool_calls) do
        local tool_line = #lines
        table.insert(lines, string.format("  > Tool: %s", tc.name))
        table.insert(highlights, { line = tool_line, col = 0, end_col = -1, hl = "GeminiTool" })
      end
    end

    table.insert(lines, "")

    if self.current_response ~= "" then
      for line in self.current_response:gmatch("[^\n]*") do
        table.insert(lines, line)
      end
    end

    table.insert(lines, "")
  end

  -- Update buffer
  api.nvim_buf_set_option(self.main_buf, "modifiable", true)
  api.nvim_buf_set_lines(self.main_buf, 0, -1, false, lines)

  -- Apply highlights
  local ns_id = api.nvim_create_namespace("gemini_chat")
  api.nvim_buf_clear_namespace(self.main_buf, ns_id, 0, -1)

  for _, hl in ipairs(highlights) do
    api.nvim_buf_add_highlight(self.main_buf, ns_id, hl.hl, hl.line, hl.col, hl.end_col)
  end

  api.nvim_buf_set_option(self.main_buf, "modifiable", false)

  -- Scroll to bottom
  if self.main_win and api.nvim_win_is_valid(self.main_win) then
    local line_count = api.nvim_buf_line_count(self.main_buf)
    api.nvim_win_set_cursor(self.main_win, { line_count, 0 })
  end
end

---Set messages (for loading history)
---@param self ChatUI
---@param messages table[]
function ChatUI:set_messages(messages)
  self.messages = messages
  self:render()
end

---Clear chat
---@param self ChatUI
function ChatUI:clear()
  self.messages = {}
  self.current_response = ""
  self.is_streaming = false
  self:render()
end

---Get all messages
---@param self ChatUI
---@return table[]
function ChatUI:get_messages()
  return self.messages
end

---Show error
---@param self ChatUI
---@param error_msg string
function ChatUI:show_error(error_msg)
  self.is_streaming = false
  self.status = ""
  self:stop_spinner()

  self:add_message({
    role = "assistant",
    content = "Error: " .. error_msg,
    timestamp = os.time() * 1000,
  })
end

---Set input text
---@param self ChatUI
---@param text string
function ChatUI:set_input(text)
  if self.input_buf and api.nvim_buf_is_valid(self.input_buf) then
    api.nvim_buf_set_lines(self.input_buf, 0, -1, false, vim.split(text, "\n"))
    self:resize_input()
  end
end

---Replace command on line 1 with its template
---@param self ChatUI
function ChatUI:replace_command_with_template()
  if not self.on_get_bang_commands then
    return
  end

  local line = api.nvim_buf_get_lines(self.input_buf, 0, 1, false)[1] or ""
  local cmd_name = line:match("^!?(%S+)$")
  if not cmd_name then
    return
  end

  local commands = self.on_get_bang_commands()
  for _, cmd in ipairs(commands) do
    if cmd.name == cmd_name then
      local template = cmd.prompt_template or ""
      api.nvim_buf_set_lines(self.input_buf, 0, 1, false, {template})
      api.nvim_win_set_cursor(0, { 1, #template })
      -- Apply command settings
      self:apply_command_settings(cmd)
      return
    end
  end
end

---Apply settings from a bang command
---@param self ChatUI
---@param cmd table
function ChatUI:apply_command_settings(cmd)
  if not cmd then return end

  -- Create or update pending_settings
  self.pending_settings = self.pending_settings or {}
  if cmd.model then
    self.pending_settings.model = cmd.model
  end
  if cmd.search_setting then
    -- Normalize to array
    if type(cmd.search_setting) == "table" then
      self.pending_settings.search_setting = cmd.search_setting
    else
      self.pending_settings.search_setting = { cmd.search_setting }
    end
  end

  -- Update settings bar
  self:render_settings_bar()
end

---Get current effective settings (pending or default)
---@param self ChatUI
---@return table
function ChatUI:get_effective_settings()
  local defaults = {}
  if self.on_get_default_settings then
    defaults = self.on_get_default_settings()
  end

  -- Normalize search_setting to array
  local search_setting = (self.pending_settings and self.pending_settings.search_setting) or defaults.search_setting
  if search_setting and type(search_setting) ~= "table" then
    search_setting = { search_setting }
  end

  return {
    model = (self.pending_settings and self.pending_settings.model) or defaults.model or "gemini-3-flash-preview",
    search_setting = search_setting,  -- array or nil
    tool_mode = self.pending_settings and self.pending_settings.tool_mode,  -- nil = auto, or "all", "noSearch", "none"
  }
end

---Render the settings bar below input
---@param self ChatUI
function ChatUI:render_settings_bar()
  if not self.settings_buf or not api.nvim_buf_is_valid(self.settings_buf) then
    return
  end

  local settings = self:get_effective_settings()

  -- Shorten model name for display
  local model_short = settings.model
  if model_short:match("^gemini%-") then
    model_short = model_short:gsub("gemini%-", ""):gsub("%-preview", "")
  elseif model_short:match("^gemma%-") then
    -- Gemma models: show as "gemma-3-27b" etc
    model_short = model_short:gsub("%-it$", "")
  elseif model_short:match("%-cli$") then
    -- CLI models: show as "CLI:claude", "CLI:gemini", "CLI:codex"
    model_short = "CLI:" .. model_short:gsub("%-cli$", "")
  end

  -- Build search text from array
  local search_text = "Off"
  local has_web = false
  local rag_count = 0

  -- CLI models don't support search
  if settings.model and settings.model:match("%-cli$") then
    search_text = "-"
  elseif settings.search_setting and #settings.search_setting > 0 then
    local parts = {}
    for _, s in ipairs(settings.search_setting) do
      if s == "__websearch__" then
        has_web = true
      else
        rag_count = rag_count + 1
      end
    end
    if has_web then table.insert(parts, "Web") end
    if rag_count > 0 then table.insert(parts, "RAG(" .. rag_count .. ")") end
    search_text = table.concat(parts, "+")
  end

  -- Determine tool mode for display
  local is_cli = settings.model and settings.model:match("%-cli$")
  local is_gemma = settings.model and settings.model:match("^gemma%-")
  local is_25flash_rag = settings.model == "gemini-2.5-flash" and rag_count > 0
  local tool_mode
  -- Use manual override if set, otherwise auto-determine
  if settings.tool_mode then
    tool_mode = settings.tool_mode == "none" and "off" or settings.tool_mode
  elseif is_cli or is_gemma or has_web or is_25flash_rag then
    tool_mode = "off"
  elseif rag_count > 0 then
    tool_mode = "noSearch"
  else
    tool_mode = "all"
  end

  -- Check if there are pending overrides
  local has_override = self.pending_settings and (self.pending_settings.model or self.pending_settings.search_setting or self.pending_settings.tool_mode)
  local override_marker = has_override and "*" or ""

  local text = string.format(" %s | Search:%s | Tools:%s %s", model_short, search_text, tool_mode, override_marker)

  api.nvim_buf_set_option(self.settings_buf, "modifiable", true)
  api.nvim_buf_set_lines(self.settings_buf, 0, -1, false, { text })
  api.nvim_buf_set_option(self.settings_buf, "modifiable", false)
end

---Show settings modal for editing
---@param self ChatUI
function ChatUI:show_settings_modal()
  -- Debug: show current pending_settings
  if self.debug_settings then
    vim.notify("pending_settings: " .. vim.inspect(self.pending_settings), vim.log.levels.DEBUG)
  end

  local settings = self:get_effective_settings()

  -- Build model options (available_models is now array of model info tables)
  local model_items = {}
  for i, model_info in ipairs(self.available_models) do
    local name = type(model_info) == "table" and model_info.name or model_info
    local display_name = type(model_info) == "table" and model_info.display_name or name
    local prefix = name == settings.model and "[x] " or "[ ] "
    table.insert(model_items, { idx = i, display = prefix .. display_name, value = name })
  end

  -- First: select model
  vim.ui.select(model_items, {
    prompt = "Select model:",
    format_item = function(item) return item.display end,
  }, function(model_selected)
    if model_selected then
      self.pending_settings = self.pending_settings or {}
      if self.pending_settings.model ~= model_selected.value then
        self.pending_settings.model = model_selected.value
        vim.notify("Model: " .. model_selected.value, vim.log.levels.INFO)
      end
    end

    -- Get the selected model (or current if not changed)
    local selected_model = (self.pending_settings and self.pending_settings.model) or settings.model

    -- CLI models don't support Web Search or RAG - skip search settings dialog
    if selected_model and selected_model:match("%-cli$") then
      -- Clear any search settings and set tool_mode to none for CLI models
      self.pending_settings = self.pending_settings or {}
      self.pending_settings.search_setting = {}
      self.pending_settings.tool_mode = "none"

      -- Update settings bar and return focus
      self:render_settings_bar()
      if self.input_win and api.nvim_win_is_valid(self.input_win) then
        api.nvim_set_current_win(self.input_win)
        vim.cmd("startinsert")
      end
      return
    end

    -- Check current search settings
    local current_search = settings.search_setting or {}
    local has_web = vim.tbl_contains(current_search, "__websearch__")
    local rag_stores = vim.tbl_filter(function(s) return s ~= "__websearch__" end, current_search)
    local has_rag = #rag_stores > 0

    -- Build search options (mutually exclusive: Web Search OR RAG stores)
    local search_items = {
      { display = (not has_web and not has_rag) and "[x] Off" or "[ ] Off", value = "off" },
      { display = has_web and "[x] Web Search" or "[ ] Web Search", value = "web" },
    }

    -- Show current RAG stores if enabled
    if has_rag then
      local rag_display = "[x] RAG: " .. table.concat(rag_stores, ", ")
      table.insert(search_items, { display = rag_display, value = "keep_rag", stores = rag_stores })
    end

    -- Always show option to change RAG
    table.insert(search_items, { display = "    Change RAG store...", value = "add_rag" })

    vim.ui.select(search_items, {
      prompt = "Search settings (Web/RAG are exclusive):",
      format_item = function(item) return item.display end,
    }, function(search_selected)
      if search_selected then
        self.pending_settings = self.pending_settings or {}

        if search_selected.value == "off" then
          self.pending_settings.search_setting = {}
          vim.notify("Search: Off", vim.log.levels.INFO)
        elseif search_selected.value == "web" then
          -- Toggle web search (clears RAG stores)
          if has_web then
            -- Turn off web search
            self.pending_settings.search_setting = {}
            vim.notify("Web Search: Off", vim.log.levels.INFO)
          else
            -- Turn on web search (exclusive - clears RAG)
            self.pending_settings.search_setting = { "__websearch__" }
            vim.notify("Web Search: On", vim.log.levels.INFO)
          end
        elseif search_selected.value == "keep_rag" then
          -- Keep current RAG stores
          self.pending_settings.search_setting = search_selected.stores
          vim.notify("RAG: " .. table.concat(search_selected.stores, ", "), vim.log.levels.INFO)
        elseif search_selected.value == "add_rag" then
          -- Fetch RAG stores and show selection dialog
          self:show_rag_store_selection(rag_stores)
          return  -- Don't continue, callback will handle flow
        end
      end

      -- Auto-update tool_mode based on new settings
      self:update_tool_mode_to_default()

      -- Update settings bar and continue to tool mode selection
      self:render_settings_bar()
      self:show_tool_mode_selection()
    end)
  end)
end

---Show RAG store selection dialog
---@param self ChatUI
---@param current_stores string[]  Currently selected store names
function ChatUI:show_rag_store_selection(current_stores)
  -- Show loading message
  vim.notify("Fetching RAG stores...", vim.log.levels.INFO)

  if not self.on_fetch_rag_stores then
    -- Fallback to manual input
    self:show_rag_store_manual_input(current_stores)
    return
  end

  self.on_fetch_rag_stores(function(stores, err)
    if err then
      vim.notify("Failed to fetch stores: " .. err, vim.log.levels.WARN)
      -- Fallback to manual input
      self:show_rag_store_manual_input(current_stores)
      return
    end

    if not stores or #stores == 0 then
      vim.notify("No RAG stores found. Use ragujuary to create one.", vim.log.levels.INFO)
      -- Fallback to manual input
      self:show_rag_store_manual_input(current_stores)
      return
    end

    -- Build selection items with checkmarks for currently selected
    local items = {}
    for _, store in ipairs(stores) do
      local store_name = store.name:gsub("^fileSearchStores/", "")
      local is_selected = vim.tbl_contains(current_stores, store_name)
      local prefix = is_selected and "[x] " or "[ ] "
      table.insert(items, {
        display = prefix .. store.display_name,
        value = store_name,
        selected = is_selected,
      })
    end
    -- Add manual input option
    table.insert(items, { display = ">> Enter manually...", value = "__manual__" })

    vim.ui.select(items, {
      prompt = "Select RAG store:",
      format_item = function(item) return item.display end,
    }, function(selected)
      if selected then
        if selected.value == "__manual__" then
          self:show_rag_store_manual_input(current_stores)
          return
        end

        -- Toggle selection or set single store
        self.pending_settings = self.pending_settings or {}
        if selected.selected then
          -- Remove from selection
          local new_stores = vim.tbl_filter(function(s)
            return s ~= selected.value
          end, current_stores)
          self.pending_settings.search_setting = new_stores
          vim.notify("RAG: " .. (next(new_stores) and table.concat(new_stores, ", ") or "Off"), vim.log.levels.INFO)
        else
          -- Add to selection (replace for now, could be multi-select)
          self.pending_settings.search_setting = { selected.value }
          vim.notify("RAG: " .. selected.value, vim.log.levels.INFO)
        end
        -- Auto-update tool_mode based on new settings
        self:update_tool_mode_to_default()
        self:render_settings_bar()
      end

      -- Continue to tool mode selection
      self:show_tool_mode_selection()
    end)
  end)
end

---Show manual RAG store input dialog
---@param self ChatUI
---@param current_stores string[]
function ChatUI:show_rag_store_manual_input(current_stores)
  local current_rag = table.concat(current_stores, ", ")
  vim.ui.input({
    prompt = "RAG stores (comma-separated): ",
    default = current_rag,
  }, function(input)
    if input and input ~= "" then
      -- Parse comma-separated store names
      local stores = {}
      for store in input:gmatch("[^,]+") do
        local trimmed = store:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
          table.insert(stores, trimmed)
        end
      end
      if #stores > 0 then
        -- RAG is exclusive - clears web search
        self.pending_settings = self.pending_settings or {}
        self.pending_settings.search_setting = stores
        vim.notify("RAG: " .. table.concat(stores, ", "), vim.log.levels.INFO)
        -- Auto-update tool_mode based on new settings
        self:update_tool_mode_to_default()
        self:render_settings_bar()
      end
    end

    -- Continue to tool mode selection
    self:show_tool_mode_selection()
  end)
end

---Calculate default tool mode based on current settings
---@param self ChatUI
---@return string "all" | "noSearch" | "none"
function ChatUI:calculate_default_tool_mode()
  local settings = self:get_effective_settings()
  local model = settings.model or ""
  local search_setting = settings.search_setting or {}

  -- CLI models: no tools
  if model:match("%-cli$") then
    return "none"
  end

  -- Gemma models: no function calling
  if model:match("^gemma%-") then
    return "none"
  end

  -- Check search settings
  local has_web = vim.tbl_contains(search_setting, "__websearch__")
  local rag_stores = vim.tbl_filter(function(s) return s ~= "__websearch__" end, search_setting)
  local has_rag = #rag_stores > 0

  -- Web search: no tools
  if has_web then
    return "none"
  end

  -- RAG with gemini-2.5-flash: no tools
  if has_rag and model == "gemini-2.5-flash" then
    return "none"
  end

  -- RAG enabled: exclude search tools
  if has_rag then
    return "noSearch"
  end

  return "all"
end

---Update tool mode to default based on current model/search settings
---@param self ChatUI
function ChatUI:update_tool_mode_to_default()
  local default_mode = self:calculate_default_tool_mode()
  self.pending_settings = self.pending_settings or {}
  self.pending_settings.tool_mode = default_mode
end

---Show tool mode selection dialog
---@param self ChatUI
function ChatUI:show_tool_mode_selection()
  local settings = self:get_effective_settings()

  -- CLI models and gemma models don't support tools - skip and set to none
  local selected_model = settings.model
  if selected_model and (selected_model:match("%-cli$") or selected_model:match("^gemma%-")) then
    self.pending_settings = self.pending_settings or {}
    self.pending_settings.tool_mode = "none"
    self:render_settings_bar()
    -- Return focus to input
    if self.input_win and api.nvim_win_is_valid(self.input_win) then
      api.nvim_set_current_win(self.input_win)
      vim.cmd("startinsert")
    end
    return
  end

  -- Get current tool mode (use calculated default if not set)
  local current_tool_mode = settings.tool_mode or self:calculate_default_tool_mode()

  -- Build tool mode options (no Auto)
  local tool_items = {
    { display = current_tool_mode == "all" and "[x] all (all tools)" or "[ ] all (all tools)", value = "all" },
    { display = current_tool_mode == "noSearch" and "[x] noSearch (exclude search)" or "[ ] noSearch (exclude search)", value = "noSearch" },
    { display = current_tool_mode == "none" and "[x] none (no tools)" or "[ ] none (no tools)", value = "none" },
  }

  vim.ui.select(tool_items, {
    prompt = "Tool mode:",
    format_item = function(item) return item.display end,
  }, function(tool_selected)
    if tool_selected then
      self.pending_settings = self.pending_settings or {}
      self.pending_settings.tool_mode = tool_selected.value
      vim.notify("Tools: " .. tool_selected.value, vim.log.levels.INFO)
    else
      -- User cancelled - use default
      self.pending_settings = self.pending_settings or {}
      self.pending_settings.tool_mode = current_tool_mode
    end

    -- Update settings bar
    self:render_settings_bar()

    -- Return focus to input
    if self.input_win and api.nvim_win_is_valid(self.input_win) then
      api.nvim_set_current_win(self.input_win)
      vim.cmd("startinsert")
    end
  end)
end

---Show bang command completions
---@param self ChatUI
function ChatUI:show_bang_completions()
  if not self.on_get_bang_commands then
    vim.notify("No bang command callback", vim.log.levels.DEBUG)
    return
  end

  local commands = self.on_get_bang_commands()
  if not commands or #commands == 0 then
    vim.notify("No commands configured. Use :GeminiAddBangCommand to add.", vim.log.levels.INFO)
    return
  end

  -- Build completion items
  local items = {}
  for _, cmd in ipairs(commands) do
    local word = cmd.name
    local menu = cmd.description or cmd.prompt_template:sub(1, 30)
    table.insert(items, { word = word, menu = menu })
  end

  -- Show completion menu (column is 1-indexed, start after !)
  local col = vim.fn.col('.')
  vim.fn.complete(col, items)
end

---Show file path completions
---@param self ChatUI
function ChatUI:show_file_completions()
  if not self.on_get_files then
    return
  end

  local files = self.on_get_files()
  if not files or #files == 0 then
    return
  end

  -- Build completion items
  local items = {}
  for _, file in ipairs(files) do
    table.insert(items, { word = file, menu = "" })
  end

  -- Get cursor position for completion start
  local col = api.nvim_win_get_cursor(0)[2]
  vim.fn.complete(col + 1, items)  -- Start after the @
end

---Get input text
---@param self ChatUI
---@return string
function ChatUI:get_input()
  if self.input_buf and api.nvim_buf_is_valid(self.input_buf) then
    local lines = api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
    return table.concat(lines, "\n")
  end
  return ""
end

return M
