-- Tool executor for Neovim
-- Maps tool calls to vault operations

local M = {}

-- Import main module to access original buffer
local function get_original_bufnr()
  local ok, gemini_helper = pcall(require, "gemini_helper")
  if ok and gemini_helper.get_original_bufnr then
    return gemini_helper.get_original_bufnr()
  end
  return nil
end

---@class ToolExecutor
---@field notes NotesManager
---@field search SearchManager
---@field settings table
local ToolExecutor = {}
ToolExecutor.__index = ToolExecutor

---Create a new tool executor
---@param notes NotesManager
---@param search SearchManager
---@param settings table
---@return ToolExecutor
function M.new(notes, search, settings)
  local self = setmetatable({}, ToolExecutor)
  self.notes = notes
  self.search = search
  self.settings = settings
  return self
end

---Execute a tool call
---@param self ToolExecutor
---@param tool_name string
---@param args table
---@return table
function ToolExecutor:execute(tool_name, args)
  local handler = self["handle_" .. tool_name]

  if not handler then
    return {
      success = false,
      error = "Unknown tool: " .. tool_name,
    }
  end

  local ok, result = pcall(handler, self, args)

  if not ok then
    return {
      success = false,
      error = "Tool execution error: " .. tostring(result),
    }
  end

  return result
end

-- Tool handlers

function ToolExecutor:handle_read_note(args)
  if args.active then
    -- Use original buffer (the one active before chat was opened)
    local bufnr = get_original_bufnr()
    local result, err = self.notes:read_active(bufnr)
    if err then
      return { success = false, error = err }
    end
    return {
      success = true,
      name = result.name,
      path = result.path,
      content = result.content,
    }
  end

  if not args.name then
    return { success = false, error = "name or active is required" }
  end

  local content, err = self.notes:read(args.name)
  if err then
    return { success = false, error = err }
  end

  return {
    success = true,
    name = args.name,
    content = content,
  }
end

function ToolExecutor:handle_search_notes(args)
  if not args.query then
    return { success = false, error = "query is required" }
  end

  local results = self.search:search(
    args.query,
    args.search_type or "both",
    args.limit or 10
  )

  local response = {
    success = true,
    results = results,
    count = #results,
  }

  -- If no results found, hint to use RAG file_search instead
  if #results == 0 then
    response.hint = "No local files found. The information may be available in the RAG file search store. Please answer based on the RAG context if available."
  end

  return response
end

function ToolExecutor:handle_list_notes(args)
  local notes = self.notes:list(args.folder, args.recursive)

  return {
    success = true,
    notes = notes,
    count = #notes,
  }
end

function ToolExecutor:handle_list_folders(args)
  local folders = self.notes:list_folders()

  return {
    success = true,
    folders = folders,
    count = #folders,
  }
end

function ToolExecutor:handle_get_active_note_info(args)
  -- Use original buffer (the one active before chat was opened)
  local bufnr = get_original_bufnr()
  local info, err = self.notes:get_active_info(bufnr)

  if err then
    return { success = false, error = err }
  end

  return {
    success = true,
    info = info,
  }
end

function ToolExecutor:handle_create_note(args)
  if not args.name or not args.content then
    return { success = false, error = "name and content are required" }
  end

  local ok, err = self.notes:create(args.name, args.content, args.folder, args.tags)

  if not ok then
    return { success = false, error = err }
  end

  return {
    success = true,
    message = "Note created: " .. args.name,
  }
end

function ToolExecutor:handle_create_folder(args)
  if not args.path then
    return { success = false, error = "path is required" }
  end

  local ok, err = self.notes:create_folder(args.path)

  if not ok then
    return { success = false, error = err }
  end

  return {
    success = true,
    message = "Folder created: " .. args.path,
  }
end

function ToolExecutor:handle_rename_note(args)
  if not args.old_path or not args.new_path then
    return { success = false, error = "old_path and new_path are required" }
  end

  local ok, err = self.notes:rename(args.old_path, args.new_path)

  if not ok then
    return { success = false, error = err }
  end

  return {
    success = true,
    message = "Note renamed from " .. args.old_path .. " to " .. args.new_path,
  }
end

function ToolExecutor:handle_update_note(args)
  if not args.name or not args.mode or not args.new_text then
    return { success = false, error = "name, mode, and new_text are required" }
  end

  if args.mode == "replace" and not args.old_text then
    return { success = false, error = "old_text is required for replace mode" }
  end

  local ok, err = self.notes:update(args.name, args.mode, args.new_text, args.old_text)

  if not ok then
    return { success = false, error = err }
  end

  return {
    success = true,
    message = "Note updated: " .. args.name,
  }
end

function ToolExecutor:handle_write_to_buffer(args)
  if not args.mode or not args.new_text then
    return { success = false, error = "mode and new_text are required" }
  end

  if args.mode == "replace" and not args.old_text then
    return { success = false, error = "old_text is required for replace mode" }
  end

  -- Get original buffer
  local bufnr = get_original_bufnr()
  if not bufnr then
    return { success = false, error = "No original buffer available. Please open a file first." }
  end

  local ok, err = self.notes:write_to_buffer(bufnr, args.mode, args.new_text, args.old_text)

  if not ok then
    return { success = false, error = err }
  end

  -- Get buffer name for message
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local display_name = bufname ~= "" and vim.fn.fnamemodify(bufname, ":t") or "[No Name]"

  return {
    success = true,
    message = "Buffer updated: " .. display_name,
  }
end

return M
