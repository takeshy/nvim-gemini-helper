-- Local search for Neovim workspace
-- Supports filename and content search with scoring

local M = {}

local Path = require("plenary.path")
local scandir = require("plenary.scandir")

---@class SearchManager
---@field workspace string
local SearchManager = {}
SearchManager.__index = SearchManager

---Create a new search manager
---@param workspace string
---@return SearchManager
function M.new(workspace)
  local self = setmetatable({}, SearchManager)
  self.workspace = workspace
  return self
end

---Calculate relevance score for filename match
---@param query string
---@param filename string
---@return number
local function filename_score(query, filename)
  local query_lower = query:lower()
  local filename_lower = filename:lower()

  -- Exact match
  if filename_lower == query_lower then
    return 100
  end

  -- Starts with query
  if filename_lower:find("^" .. vim.pesc(query_lower)) then
    return 80
  end

  -- Contains query as word
  if filename_lower:find("%f[%w]" .. vim.pesc(query_lower) .. "%f[%W]") then
    return 70
  end

  -- Contains query
  if filename_lower:find(vim.pesc(query_lower)) then
    return 50
  end

  -- Fuzzy match (all characters in order)
  local pattern = ""
  for char in query_lower:gmatch(".") do
    pattern = pattern .. vim.pesc(char) .. ".*"
  end
  if filename_lower:match(pattern) then
    return 30
  end

  return 0
end

---Calculate relevance score for content match
---@param query string
---@param content string
---@return number, number
local function content_score(query, content)
  local query_lower = query:lower()
  local content_lower = content:lower()

  local score = 0
  local match_count = 0

  -- Count occurrences
  local start_pos = 1
  while true do
    local found = content_lower:find(vim.pesc(query_lower), start_pos, true)
    if not found then break end
    match_count = match_count + 1
    start_pos = found + 1
  end

  if match_count > 0 then
    -- Base score for having matches
    score = 40

    -- Bonus for multiple matches (diminishing returns)
    score = score + math.min(match_count * 5, 30)

    -- Bonus for query appearing in first 200 chars (likely in title/heading)
    if content_lower:sub(1, 200):find(vim.pesc(query_lower)) then
      score = score + 20
    end
  end

  return score, match_count
end

---Get context around a match
---@param content string
---@param query string
---@param context_chars number
---@return string|nil
local function get_match_context(content, query, context_chars)
  context_chars = context_chars or 100
  local query_lower = query:lower()
  local content_lower = content:lower()

  local match_start = content_lower:find(vim.pesc(query_lower))
  if not match_start then
    return nil
  end

  local start_pos = math.max(1, match_start - context_chars)
  local end_pos = math.min(#content, match_start + #query + context_chars)

  local context = content:sub(start_pos, end_pos)

  -- Clean up (replace newlines with spaces, trim)
  context = context:gsub("\n", " "):gsub("%s+", " ")

  -- Add ellipsis if truncated
  if start_pos > 1 then
    context = "..." .. context
  end
  if end_pos < #content then
    context = context .. "..."
  end

  return context
end

---Search notes by filename
---@param self SearchManager
---@param query string
---@param limit? number
---@return table[]
function SearchManager:search_filename(query, limit)
  limit = limit or 10

  local results = {}

  local files = scandir.scan_dir(self.workspace, {
    hidden = false,
    add_dirs = false,
    respect_gitignore = true,
    depth = 99,
    search_pattern = "%.md$",
  })

  for _, filepath in ipairs(files) do
    local relative_path = filepath:sub(#self.workspace + 2)
    local filename = vim.fn.fnamemodify(filepath, ":t:r")

    local score = filename_score(query, filename)

    if score > 0 then
      table.insert(results, {
        name = filename,
        path = relative_path,
        score = score,
        match_type = "filename",
      })
    end
  end

  -- Sort by score descending
  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  -- Limit results
  local limited = {}
  for i = 1, math.min(limit, #results) do
    table.insert(limited, results[i])
  end

  return limited
end

---Search notes by content
---@param self SearchManager
---@param query string
---@param limit? number
---@return table[]
function SearchManager:search_content(query, limit)
  limit = limit or 10

  local results = {}

  local files = scandir.scan_dir(self.workspace, {
    hidden = false,
    add_dirs = false,
    respect_gitignore = true,
    depth = 99,
    search_pattern = "%.md$",
  })

  for _, filepath in ipairs(files) do
    local relative_path = filepath:sub(#self.workspace + 2)
    local filename = vim.fn.fnamemodify(filepath, ":t:r")

    local content = Path:new(filepath):read()
    if content then
      local score, match_count = content_score(query, content)

      if score > 0 then
        local context = get_match_context(content, query, 100)

        table.insert(results, {
          name = filename,
          path = relative_path,
          score = score,
          match_count = match_count,
          match_type = "content",
          context = context,
        })
      end
    end
  end

  -- Sort by score descending
  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  -- Limit results
  local limited = {}
  for i = 1, math.min(limit, #results) do
    table.insert(limited, results[i])
  end

  return limited
end

---Search notes by both filename and content
---@param self SearchManager
---@param query string
---@param limit? number
---@return table[]
function SearchManager:search_both(query, limit)
  limit = limit or 10

  local results = {}
  local seen = {}

  local files = scandir.scan_dir(self.workspace, {
    hidden = false,
    add_dirs = false,
    respect_gitignore = true,
    depth = 99,
    search_pattern = "%.md$",
  })

  for _, filepath in ipairs(files) do
    local relative_path = filepath:sub(#self.workspace + 2)
    local filename = vim.fn.fnamemodify(filepath, ":t:r")

    local fname_score = filename_score(query, filename)

    local content = Path:new(filepath):read()
    local cont_score = 0
    local match_count = 0
    local context = nil

    if content then
      cont_score, match_count = content_score(query, content)
      if cont_score > 0 then
        context = get_match_context(content, query, 100)
      end
    end

    -- Combine scores (filename matches weighted higher)
    local total_score = fname_score + cont_score * 0.7

    if total_score > 0 then
      local match_type = "both"
      if fname_score > 0 and cont_score == 0 then
        match_type = "filename"
      elseif fname_score == 0 and cont_score > 0 then
        match_type = "content"
      end

      table.insert(results, {
        name = filename,
        path = relative_path,
        score = total_score,
        filename_score = fname_score,
        content_score = cont_score,
        match_count = match_count,
        match_type = match_type,
        context = context,
      })
    end
  end

  -- Sort by score descending
  table.sort(results, function(a, b)
    return a.score > b.score
  end)

  -- Limit results
  local limited = {}
  for i = 1, math.min(limit, #results) do
    table.insert(limited, results[i])
  end

  return limited
end

---Main search function
---@param self SearchManager
---@param query string
---@param search_type? string
---@param limit? number
---@return table[]
function SearchManager:search(query, search_type, limit)
  search_type = search_type or "both"
  limit = limit or 10

  if search_type == "filename" then
    return self:search_filename(query, limit)
  elseif search_type == "content" then
    return self:search_content(query, limit)
  else
    return self:search_both(query, limit)
  end
end

return M
