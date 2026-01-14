-- Tool definitions for Gemini function calling
-- Defines all available tools for vault operations

local M = {}

---@class ToolDefinition
---@field name string
---@field description string
---@field parameters table
---@field category string

-- Tool modes
M.TOOL_MODES = { "all", "noSearch", "none" }

-- Search tool names (excluded in noSearch mode)
M.SEARCH_TOOLS = { "search_notes", "list_notes", "list_folders" }

-- Read operations (always available)
M.read_note = {
  name = "read_note",
  description = "Read the contents of a note. Use 'name' to specify a note, or set 'active' to true to read the currently active buffer.",
  category = "read",
  parameters = {
    type = "object",
    properties = {
      name = {
        type = "string",
        description = "The name or path of the note to read (without .md extension)",
      },
      active = {
        type = "boolean",
        description = "If true, read the currently active buffer",
      },
    },
  },
}

M.search_notes = {
  name = "search_notes",
  description = "Search for notes by filename or content. Returns matching notes with relevance scores.",
  category = "read",
  parameters = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "The search query",
      },
      search_type = {
        type = "string",
        enum = { "filename", "content", "both" },
        description = "Type of search: 'filename' for name matching, 'content' for full-text, 'both' for combined",
      },
      limit = {
        type = "integer",
        description = "Maximum number of results to return (default: 10)",
      },
    },
    required = { "query" },
  },
}

M.list_notes = {
  name = "list_notes",
  description = "List all notes in a folder or the entire workspace.",
  category = "read",
  parameters = {
    type = "object",
    properties = {
      folder = {
        type = "string",
        description = "Folder path to list (empty for root)",
      },
      recursive = {
        type = "boolean",
        description = "If true, include notes in subfolders",
      },
    },
  },
}

M.list_folders = {
  name = "list_folders",
  description = "List all folders in the workspace.",
  category = "read",
  parameters = {
    type = "object",
    properties = vim.empty_dict(),
  },
}

M.get_active_note_info = {
  name = "get_active_note_info",
  description = "Get workspace/cwd info and metadata about the currently active buffer. Always returns workspace and cwd paths, even if no file is open.",
  category = "read",
  parameters = {
    type = "object",
    properties = vim.empty_dict(),
  },
}

-- Write operations (require allow_write)
M.create_note = {
  name = "create_note",
  description = "Create a new note with the specified content.",
  category = "write",
  parameters = {
    type = "object",
    properties = {
      name = {
        type = "string",
        description = "Name of the note (without .md extension)",
      },
      content = {
        type = "string",
        description = "Content of the note",
      },
      folder = {
        type = "string",
        description = "Folder to create the note in (optional)",
      },
      tags = {
        type = "array",
        items = { type = "string" },
        description = "Tags to add to the note frontmatter (optional)",
      },
    },
    required = { "name", "content" },
  },
}

M.create_folder = {
  name = "create_folder",
  description = "Create a new folder at the specified path.",
  category = "write",
  parameters = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Path of the folder to create",
      },
    },
    required = { "path" },
  },
}

M.rename_note = {
  name = "rename_note",
  description = "Rename or move a note to a new path.",
  category = "write",
  parameters = {
    type = "object",
    properties = {
      old_path = {
        type = "string",
        description = "Current path of the note",
      },
      new_path = {
        type = "string",
        description = "New path for the note",
      },
    },
    required = { "old_path", "new_path" },
  },
}

M.update_note = {
  name = "update_note",
  description = "Update a note's content. Modes: 'replace' replaces specified text, 'append' adds to end, 'prepend' adds to beginning, 'full' replaces entire content. User can undo with Vim's :u command.",
  category = "write",
  parameters = {
    type = "object",
    properties = {
      name = {
        type = "string",
        description = "Name or path of the note to edit",
      },
      mode = {
        type = "string",
        enum = { "replace", "append", "prepend", "full" },
        description = "Edit mode",
      },
      old_text = {
        type = "string",
        description = "Text to replace (required for 'replace' mode)",
      },
      new_text = {
        type = "string",
        description = "New text to insert",
      },
    },
    required = { "name", "mode", "new_text" },
  },
}

M.write_to_buffer = {
  name = "write_to_buffer",
  description = "Write content directly to the currently active buffer (the buffer user was editing before opening chat). Works with both saved and unsaved buffers. Modes: 'replace' replaces specified text, 'append' adds to end, 'prepend' adds to beginning, 'full' replaces entire content, 'insert_at_cursor' inserts at cursor position. User can undo with Vim's :u command.",
  category = "write",
  parameters = {
    type = "object",
    properties = {
      mode = {
        type = "string",
        enum = { "replace", "append", "prepend", "full", "insert_at_cursor" },
        description = "Edit mode",
      },
      old_text = {
        type = "string",
        description = "Text to replace (required for 'replace' mode)",
      },
      new_text = {
        type = "string",
        description = "New text to insert",
      },
    },
    required = { "mode", "new_text" },
  },
}

---Get enabled tools based on settings
---@param opts table { allow_write?: boolean, tool_mode?: string }
---@return ToolDefinition[]
function M.get_enabled_tools(opts)
  opts = opts or {}
  local allow_write = opts.allow_write or false
  local tool_mode = opts.tool_mode or "all"

  -- none mode: no tools at all
  if tool_mode == "none" then
    return {}
  end

  local tools = {}

  -- Always include core read tools
  table.insert(tools, M.read_note)
  table.insert(tools, M.get_active_note_info)

  -- Search tools (excluded in noSearch mode)
  if tool_mode ~= "noSearch" then
    table.insert(tools, M.search_notes)
    table.insert(tools, M.list_notes)
    table.insert(tools, M.list_folders)
  end

  -- Include write tools if allowed
  if allow_write then
    table.insert(tools, M.create_note)
    table.insert(tools, M.create_folder)
    table.insert(tools, M.rename_note)
    table.insert(tools, M.update_note)
    table.insert(tools, M.write_to_buffer)
  end

  return tools
end

---Determine tool mode based on current settings
---@param opts table { is_cli_model?: boolean, web_search_enabled?: boolean, rag_enabled?: boolean, model?: string }
---@return string "all" | "noSearch" | "none"
function M.get_tool_mode(opts)
  opts = opts or {}

  -- CLI models: no tools (CLI doesn't support function calling)
  if opts.is_cli_model then
    return "none"
  end

  -- Web search: no tools (google_search tool only)
  if opts.web_search_enabled then
    return "none"
  end

  -- gemma models: no function calling support
  if opts.model then
    local gemini = require("gemini_helper.core.gemini")
    if not gemini.supports_function_calling(opts.model) then
      return "none"
    end
  end

  -- RAG enabled: exclude search tools (RAG handles search)
  -- gemini-2.5-flash with RAG: no tools (doesn't work well with function calling + RAG)
  if opts.rag_enabled then
    if opts.model == "gemini-2.5-flash" then
      return "none"
    end
    return "noSearch"
  end

  return "all"
end

---Get tool by name
---@param name string
---@return ToolDefinition|nil
function M.get_tool(name)
  return M[name]
end

---Get all tool names
---@return string[]
function M.get_all_tool_names()
  return {
    "read_note",
    "search_notes",
    "list_notes",
    "list_folders",
    "get_active_note_info",
    "create_note",
    "create_folder",
    "rename_note",
    "update_note",
    "write_to_buffer",
  }
end

return M
