-- Chat UI for Neovim
-- Provides floating window interface for Gemini chat

local M = {}

local api = vim.api

---@class ChatUI
---@field main_buf number
---@field main_win number
---@field input_buf number
---@field input_win number
---@field messages table[]
---@field on_send function
---@field on_stop function
---@field is_streaming boolean
---@field current_response string
---@field status string
---@field tool_calls table[]
---@field model_name string
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
  self.is_streaming = false
  self.current_response = ""
  self.status = ""
  self.tool_calls = {}
  self.width = opts.width or 50
  self.height = opts.height or 20
  self.position = opts.position or "right" -- "right", "bottom", "center"
  self.spinner_timer = nil
  self.model_name = opts.model_name or "Gemini"
  return self
end

---Calculate window dimensions
---@param self ChatUI
---@return table, table
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

  local main_config = {
    relative = "editor",
    width = width,
    height = height - 4, -- Leave room for input
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
    height = 1,
    col = col,
    row = row + height - 3,
    style = "minimal",
    border = "rounded",
    title = " Enter: send | S-Enter: newline | C-c: stop | q: close ",
    title_pos = "center",
  }

  return main_config, input_config
end

---Open the chat window
---@param self ChatUI
function ChatUI:open()
  setup_highlights()

  local main_config, input_config = self:calculate_dimensions()

  -- Create main buffer
  self.main_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(self.main_buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.main_buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(self.main_buf, "filetype", "markdown")

  -- Create input buffer
  self.input_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(self.input_buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.input_buf, "bufhidden", "wipe")

  -- Open windows
  self.main_win = api.nvim_open_win(self.main_buf, false, main_config)
  self.input_win = api.nvim_open_win(self.input_buf, true, input_config)

  -- Set window options
  api.nvim_win_set_option(self.main_win, "wrap", true)
  api.nvim_win_set_option(self.main_win, "linebreak", true)
  api.nvim_win_set_option(self.main_win, "cursorline", false)

  api.nvim_win_set_option(self.input_win, "wrap", true)

  -- Set keymaps for input buffer
  local input_opts = { noremap = true, silent = true, buffer = self.input_buf }

  -- Send with Enter (both insert and normal mode)
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    self:send_message()
  end, input_opts)

  -- Shift+Enter for newline in insert mode
  vim.keymap.set("i", "<S-CR>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
  end, input_opts)

  -- Ctrl+s also sends (alternative)
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
  self.main_win = nil
  self.input_win = nil
end

---Check if window is open
---@param self ChatUI
---@return boolean
function ChatUI:is_open()
  return self.main_win and api.nvim_win_is_valid(self.main_win)
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

  -- Clear input
  api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })

  -- Add user message
  self:add_message({
    role = "user",
    content = message,
    timestamp = os.time() * 1000,
  })

  -- Call send handler
  if self.on_send then
    self.on_send(message)
  end
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
  self.status = "Connecting to Gemini API..."
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

  if self.current_response ~= "" then
    local content = self.current_response
    if aborted then
      content = content .. "\n\n*(Generation stopped)*"
    end
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

---Render the chat
---@param self ChatUI
function ChatUI:render()
  if not self.main_buf or not api.nvim_buf_is_valid(self.main_buf) then
    return
  end

  local lines = {}
  local highlights = {}

  for _, msg in ipairs(self.messages) do
    local role_name = msg.role == "user" and "You" or self.model_name
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
    table.insert(lines, string.format("### %s %s", self.model_name, spinner))
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
  end
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
