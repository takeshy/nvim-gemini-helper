-- Tool definitions for Gemini function calling
-- Defines all available tools for vault operations

local M = {}

---@class ToolDefinition
---@field name string
---@field description string
---@field parameters table
---@field category string

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
  description = "Get metadata about the currently active buffer including name, path, and basic stats.",
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

---Get enabled tools based on settings
---@param opts table
---@return ToolDefinition[]
function M.get_enabled_tools(opts)
  opts = opts or {}
  local allow_write = opts.allow_write or false

  local tools = {}

  -- Always include read tools
  table.insert(tools, M.read_note)
  table.insert(tools, M.search_notes)
  table.insert(tools, M.list_notes)
  table.insert(tools, M.list_folders)
  table.insert(tools, M.get_active_note_info)

  -- Include write tools if allowed
  if allow_write then
    table.insert(tools, M.create_note)
    table.insert(tools, M.create_folder)
    table.insert(tools, M.rename_note)
    table.insert(tools, M.update_note)
  end

  return tools
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
  }
end

return M
