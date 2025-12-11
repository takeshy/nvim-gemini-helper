-- Chat history manager for Neovim
-- Saves and loads chat history as Markdown files

local M = {}

local Path = require("plenary.path")
local scandir = require("plenary.scandir")
local json = vim.json

---@class ChatHistory
---@field chats_folder string
local ChatHistory = {}
ChatHistory.__index = ChatHistory

---Create a new chat history manager
---@param chats_folder string
---@return ChatHistory
function M.new(chats_folder)
  local self = setmetatable({}, ChatHistory)
  self.chats_folder = chats_folder
  vim.fn.mkdir(chats_folder, "p")
  return self
end

---Generate a unique chat ID
---@return string
local function generate_chat_id()
  local timestamp = os.time() * 1000
  local random_part = string.format("%08x", math.random(0, 0xFFFFFFFF))
  return string.format("chat_%d_%s", timestamp, random_part)
end

---Format timestamp for display
---@param timestamp number
---@return string
local function format_time(timestamp)
  return os.date("%H:%M:%S", math.floor(timestamp / 1000))
end

---Format date for display
---@param timestamp number
---@return string
local function format_date(timestamp)
  return os.date("%Y-%m-%d %H:%M", math.floor(timestamp / 1000))
end

---Escape text for Markdown
---@param text string
---@return string
local function escape_markdown(text)
  return text
end

---Convert messages to Markdown format
---@param messages table[]
---@param title string
---@param created_at number
---@param updated_at number
---@return string
function M.messages_to_markdown(messages, title, created_at, updated_at)
  local lines = {}

  -- YAML frontmatter
  table.insert(lines, "---")
  table.insert(lines, string.format('title: "%s"', title:gsub('"', '\\"')))
  table.insert(lines, string.format("createdAt: %d", created_at))
  table.insert(lines, string.format("updatedAt: %d", updated_at))
  table.insert(lines, "---")
  table.insert(lines, "")

  -- Title heading
  table.insert(lines, "# " .. title)
  table.insert(lines, "")
  table.insert(lines, "*Created: " .. format_date(created_at) .. "*")
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  -- Messages
  for _, msg in ipairs(messages) do
    local role_name = msg.role == "user" and "You" or "Gemini"
    local time_str = format_time(msg.timestamp or os.time() * 1000)

    table.insert(lines, string.format("## **%s** (%s)", role_name, time_str))
    table.insert(lines, "")

    -- Attachments
    if msg.attachments and #msg.attachments > 0 then
      local names = {}
      for _, att in ipairs(msg.attachments) do
        table.insert(names, att.name)
      end
      table.insert(lines, "> Attachments: " .. table.concat(names, ", "))
      table.insert(lines, "")
    end

    -- Tools used
    if msg.tools_used and #msg.tools_used > 0 then
      table.insert(lines, "> Tools: " .. table.concat(msg.tools_used, ", "))
      table.insert(lines, "")
    end

    -- RAG sources
    if msg.rag_sources and #msg.rag_sources > 0 then
      table.insert(lines, "> RAG Sources: " .. table.concat(msg.rag_sources, ", "))
      table.insert(lines, "")
    end

    -- Content
    table.insert(lines, escape_markdown(msg.content))
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  return table.concat(lines, "\n")
end

---Parse Markdown to messages
---@param content string
---@return table|nil, table[]
function M.parse_markdown_to_messages(content)
  local messages = {}
  local metadata = nil

  -- Parse YAML frontmatter
  local frontmatter_match = content:match("^%-%-%-\n(.-)\n%-%-%-")
  if frontmatter_match then
    metadata = {}
    for line in frontmatter_match:gmatch("[^\n]+") do
      local key, value = line:match("^(%w+):%s*(.+)$")
      if key and value then
        -- Remove quotes from strings
        value = value:gsub('^"(.*)"$', "%1")
        -- Convert numbers
        local num = tonumber(value)
        if num then
          value = num
        end
        metadata[key] = value
      end
    end
  end

  -- Parse messages
  local message_pattern = "## %*%*(.-)%*%* %((%d+:%d+:%d+)%)\n(.-)\n%-%-%-"

  for role_name, time_str, body in content:gmatch(message_pattern) do
    local role = role_name == "You" and "user" or "assistant"

    -- Parse metadata from body
    local attachments_str = body:match("> Attachments: ([^\n]+)")
    local tools_str = body:match("> Tools: ([^\n]+)")
    local rag_sources_str = body:match("> RAG Sources: ([^\n]+)")

    -- Remove metadata lines from content
    local msg_content = body
    msg_content = msg_content:gsub("> Attachments: [^\n]+\n?", "")
    msg_content = msg_content:gsub("> Tools: [^\n]+\n?", "")
    msg_content = msg_content:gsub("> RAG Sources: [^\n]+\n?", "")
    msg_content = msg_content:gsub("^%s+", ""):gsub("%s+$", "")

    local msg = {
      role = role,
      content = msg_content,
      timestamp = os.time() * 1000, -- Approximate
    }

    -- Parse attachments (names only, data not stored)
    if attachments_str then
      msg.attachments = {}
      for name in attachments_str:gmatch("[^,]+") do
        table.insert(msg.attachments, { name = name:gsub("^%s+", ""):gsub("%s+$", "") })
      end
    end

    -- Parse tools
    if tools_str then
      msg.tools_used = {}
      for name in tools_str:gmatch("[^,]+") do
        table.insert(msg.tools_used, name:gsub("^%s+", ""):gsub("%s+$", ""))
      end
    end

    -- Parse RAG sources
    if rag_sources_str then
      msg.rag_sources = {}
      for name in rag_sources_str:gmatch("[^,]+") do
        table.insert(msg.rag_sources, name:gsub("^%s+", ""):gsub("%s+$", ""))
      end
    end

    table.insert(messages, msg)
  end

  return metadata, messages
end

---Save a chat
---@param self ChatHistory
---@param chat_id string|nil
---@param messages table[]
---@param title string|nil
---@return string
function ChatHistory:save(chat_id, messages, title)
  chat_id = chat_id or generate_chat_id()

  -- Generate title from first message if not provided
  if not title or title == "" then
    if #messages > 0 then
      title = messages[1].content:sub(1, 50)
      if #messages[1].content > 50 then
        title = title .. "..."
      end
    else
      title = "New Chat"
    end
  end

  local now = os.time() * 1000
  local created_at = now
  local updated_at = now

  -- Check if chat exists to preserve created_at
  local existing_path = Path:new(self.chats_folder, chat_id .. ".md")
  if existing_path:exists() then
    local existing_content = existing_path:read()
    local metadata, _ = M.parse_markdown_to_messages(existing_content)
    if metadata and metadata.createdAt then
      created_at = metadata.createdAt
    end
  end

  local markdown = M.messages_to_markdown(messages, title, created_at, updated_at)

  local filepath = Path:new(self.chats_folder, chat_id .. ".md")
  filepath:write(markdown, "w")

  return chat_id
end

---Load a chat
---@param self ChatHistory
---@param chat_id string
---@return table|nil, table[]|nil
function ChatHistory:load(chat_id)
  local filepath = Path:new(self.chats_folder, chat_id .. ".md")

  if not filepath:exists() then
    return nil, nil
  end

  local content = filepath:read()
  return M.parse_markdown_to_messages(content)
end

---List all chats
---@param self ChatHistory
---@param limit? number
---@return table[]
function ChatHistory:list(limit)
  limit = limit or 50

  local chats = {}

  local files = scandir.scan_dir(self.chats_folder, {
    hidden = false,
    add_dirs = false,
    depth = 1,
    search_pattern = "%.md$",
  })

  for _, filepath in ipairs(files) do
    local chat_id = vim.fn.fnamemodify(filepath, ":t:r")

    local content = Path:new(filepath):read()
    local metadata, _ = M.parse_markdown_to_messages(content)

    if metadata then
      table.insert(chats, {
        id = chat_id,
        title = metadata.title or "Untitled",
        created_at = metadata.createdAt,
        updated_at = metadata.updatedAt,
        path = filepath,
      })
    end
  end

  -- Sort by updated_at descending
  table.sort(chats, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)

  -- Limit results
  local limited = {}
  for i = 1, math.min(limit, #chats) do
    table.insert(limited, chats[i])
  end

  return limited
end

---Delete a chat
---@param self ChatHistory
---@param chat_id string
---@return boolean
function ChatHistory:delete(chat_id)
  local filepath = Path:new(self.chats_folder, chat_id .. ".md")

  if not filepath:exists() then
    return false
  end

  vim.fn.delete(filepath:absolute())
  return true
end

---Delete old chats (keep most recent N)
---@param self ChatHistory
---@param keep_count number
---@return number
function ChatHistory:cleanup(keep_count)
  keep_count = keep_count or 50

  local chats = self:list(1000)
  local deleted = 0

  for i = keep_count + 1, #chats do
    if self:delete(chats[i].id) then
      deleted = deleted + 1
    end
  end

  return deleted
end

---Create a new chat
---@param self ChatHistory
---@return string
function ChatHistory:create_new()
  return generate_chat_id()
end

return M
