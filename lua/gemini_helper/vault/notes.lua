-- Note operations for Neovim
-- Provides CRUD operations and safe editing workflow

local M = {}

local Path = require("plenary.path")
local scandir = require("plenary.scandir")

---@class NotesManager
---@field workspace string
local NotesManager = {}
NotesManager.__index = NotesManager

---Create a new notes manager
---@param workspace string
---@return NotesManager
function M.new(workspace)
  local self = setmetatable({}, NotesManager)
  self.workspace = workspace
  return self
end

---Resolve note path from name
---@param self NotesManager
---@param name string
---@return string
function NotesManager:resolve_path(name)
  -- Remove .md extension if present
  name = name:gsub("%.md$", "")

  local path = Path:new(self.workspace, name .. ".md")
  return path:absolute()
end

---Check if note exists
---@param self NotesManager
---@param name string
---@return boolean
function NotesManager:exists(name)
  local path = self:resolve_path(name)
  return vim.fn.filereadable(path) == 1
end

---Read note content
---@param self NotesManager
---@param name string
---@return string|nil, string|nil
function NotesManager:read(name)
  local path = self:resolve_path(name)

  if vim.fn.filereadable(path) == 0 then
    return nil, "Note not found: " .. name
  end

  local content = Path:new(path):read()
  return content, nil
end

---Read active buffer
---@param self NotesManager
---@param bufnr? number  Optional buffer number (uses current if not provided)
---@return table|nil, string|nil
function NotesManager:read_active(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Invalid buffer"
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if filepath == "" then
    return nil, "No active file (buffer has no file)"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Get relative path
  local relative_path = filepath
  if filepath:sub(1, #self.workspace) == self.workspace then
    relative_path = filepath:sub(#self.workspace + 2)
  end

  return {
    name = vim.fn.fnamemodify(filepath, ":t:r"),
    path = relative_path,
    content = content,
  }, nil
end

---Get active buffer info
---@param self NotesManager
---@param bufnr? number  Optional buffer number (uses current if not provided)
---@return table|nil, string|nil
function NotesManager:get_active_info(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Always include workspace info
  local result = {
    workspace = self.workspace,
    cwd = vim.fn.getcwd(),
  }

  if not vim.api.nvim_buf_is_valid(bufnr) then
    result.note = nil
    result.message = "Invalid buffer"
    return result, nil
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if filepath == "" then
    result.note = nil
    result.message = "No active file (buffer has no file)"
    return result, nil
  end

  local stat = vim.loop.fs_stat(filepath)

  -- Get relative path
  local relative_path = filepath
  if filepath:sub(1, #self.workspace) == self.workspace then
    relative_path = filepath:sub(#self.workspace + 2)
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  result.note = {
    name = vim.fn.fnamemodify(filepath, ":t:r"),
    path = relative_path,
    full_path = filepath,
    line_count = line_count,
    size = stat and stat.size or 0,
    modified = vim.api.nvim_buf_get_option(bufnr, "modified"),
    filetype = vim.api.nvim_buf_get_option(bufnr, "filetype"),
  }

  return result, nil
end

---Create a new note
---@param self NotesManager
---@param name string
---@param content string
---@param folder? string
---@param tags? string[]
---@return boolean, string|nil
function NotesManager:create(name, content, folder, tags)
  -- Build path
  local note_path
  if folder and folder ~= "" then
    note_path = Path:new(self.workspace, folder, name .. ".md")
    -- Ensure folder exists
    Path:new(self.workspace, folder):mkdir({ parents = true })
  else
    note_path = Path:new(self.workspace, name .. ".md")
  end

  local full_path = note_path:absolute()

  -- Check if exists
  if vim.fn.filereadable(full_path) == 1 then
    return false, "Note already exists: " .. name
  end

  -- Add frontmatter with tags if provided
  local final_content = content
  if tags and #tags > 0 then
    local frontmatter = "---\n"
    frontmatter = frontmatter .. "tags:\n"
    for _, tag in ipairs(tags) do
      frontmatter = frontmatter .. "  - " .. tag .. "\n"
    end
    frontmatter = frontmatter .. "---\n\n"
    final_content = frontmatter .. content
  end

  -- Write file
  note_path:write(final_content, "w")

  return true, nil
end

---Create a folder
---@param self NotesManager
---@param path string
---@return boolean, string|nil
function NotesManager:create_folder(path)
  local folder_path = Path:new(self.workspace, path)

  if vim.fn.isdirectory(folder_path:absolute()) == 1 then
    return false, "Folder already exists: " .. path
  end

  folder_path:mkdir({ parents = true })
  return true, nil
end

---Rename/move a note
---@param self NotesManager
---@param old_path string
---@param new_path string
---@return boolean, string|nil
function NotesManager:rename(old_path, new_path)
  local old_full = self:resolve_path(old_path)
  local new_full = self:resolve_path(new_path)

  if vim.fn.filereadable(old_full) == 0 then
    return false, "Note not found: " .. old_path
  end

  if vim.fn.filereadable(new_full) == 1 then
    return false, "Target already exists: " .. new_path
  end

  -- Ensure parent directory exists
  local parent = vim.fn.fnamemodify(new_full, ":h")
  vim.fn.mkdir(parent, "p")

  -- Rename
  local ok = vim.loop.fs_rename(old_full, new_full)
  if not ok then
    return false, "Failed to rename note"
  end

  return true, nil
end

---Update a note's content
---@param self NotesManager
---@param name string
---@param mode string
---@param new_text string
---@param old_text? string
---@return boolean, string|nil
function NotesManager:update(name, mode, new_text, old_text)
  local path = self:resolve_path(name)

  if vim.fn.filereadable(path) == 0 then
    return false, "Note not found: " .. name
  end

  -- Read original content
  local original_content = Path:new(path):read()

  -- Calculate new content based on mode
  local new_content
  if mode == "replace" then
    if not old_text then
      return false, "old_text is required for replace mode"
    end
    if not original_content:find(old_text, 1, true) then
      return false, "old_text not found in note"
    end
    new_content = original_content:gsub(vim.pesc(old_text), new_text, 1)
  elseif mode == "append" then
    new_content = original_content .. "\n" .. new_text
  elseif mode == "prepend" then
    new_content = new_text .. "\n" .. original_content
  elseif mode == "full" then
    new_content = new_text
  else
    return false, "Invalid mode: " .. mode
  end

  -- Apply edit to file
  Path:new(path):write(new_content, "w")

  -- Reload buffer if open (preserves undo history)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("edit!")
    end)
  end

  return true, nil
end

---List notes in a folder
---@param self NotesManager
---@param folder? string
---@param recursive? boolean
---@return table[]
function NotesManager:list(folder, recursive)
  local base_path = folder and Path:new(self.workspace, folder):absolute() or self.workspace

  if vim.fn.isdirectory(base_path) == 0 then
    return {}
  end

  local notes = {}
  local found = scandir.scan_dir(base_path, {
    hidden = false,
    add_dirs = false,
    respect_gitignore = true,
    depth = recursive and 99 or 1,
    search_pattern = "%.md$",
  })

  for _, filepath in ipairs(found) do
    local relative_path = filepath:sub(#self.workspace + 2)
    local name = vim.fn.fnamemodify(relative_path, ":t:r")

    table.insert(notes, {
      name = name,
      path = relative_path,
    })
  end

  return notes
end

---List all folders
---@param self NotesManager
---@return string[]
function NotesManager:list_folders(max_depth, max_count)
  max_depth = max_depth or 3
  max_count = max_count or 100
  local folders = {}

  local found = scandir.scan_dir(self.workspace, {
    hidden = false,
    add_dirs = true,
    only_dirs = true,
    respect_gitignore = true,
    depth = max_depth,
  })

  for _, dirpath in ipairs(found) do
    local relative_path = dirpath:sub(#self.workspace + 2)
    if relative_path ~= "" then
      table.insert(folders, relative_path)
      if #folders >= max_count then
        break
      end
    end
  end

  return folders
end

---Write to buffer directly
---@param self NotesManager
---@param bufnr number
---@param mode string
---@param new_text string
---@param old_text? string
---@return boolean, string|nil
function NotesManager:write_to_buffer(bufnr, mode, new_text, old_text)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "Invalid buffer"
  end

  -- Get current content
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local original_content = table.concat(lines, "\n")

  -- Calculate new content based on mode
  local new_content
  if mode == "replace" then
    if not old_text then
      return false, "old_text is required for replace mode"
    end
    if not original_content:find(old_text, 1, true) then
      return false, "old_text not found in buffer"
    end
    new_content = original_content:gsub(vim.pesc(old_text), new_text, 1)
  elseif mode == "append" then
    new_content = original_content .. "\n" .. new_text
  elseif mode == "prepend" then
    new_content = new_text .. "\n" .. original_content
  elseif mode == "full" then
    new_content = new_text
  elseif mode == "insert_at_cursor" then
    -- Insert at cursor position in the original buffer
    -- We need to get cursor position from the original buffer window
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins > 0 then
      local win = wins[1]
      local cursor = vim.api.nvim_win_get_cursor(win)
      local row = cursor[1] - 1  -- 0-indexed
      local col = cursor[2]

      -- Split content into lines
      local new_lines = vim.split(new_text, "\n", { plain = true })

      -- Get current line
      local current_line = lines[row + 1] or ""

      -- Insert text at cursor position
      local before = current_line:sub(1, col)
      local after = current_line:sub(col + 1)

      if #new_lines == 1 then
        lines[row + 1] = before .. new_lines[1] .. after
      else
        -- Multiple lines
        lines[row + 1] = before .. new_lines[1]
        for i = 2, #new_lines - 1 do
          table.insert(lines, row + i, new_lines[i])
        end
        table.insert(lines, row + #new_lines, new_lines[#new_lines] .. after)
      end

      new_content = table.concat(lines, "\n")
    else
      -- No window found, just append
      new_content = original_content .. "\n" .. new_text
    end
  else
    return false, "Invalid mode: " .. mode
  end

  -- Apply changes to buffer
  local new_lines = vim.split(new_content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

  return true, nil
end

return M
