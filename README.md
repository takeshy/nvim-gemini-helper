# Gemini Helper for Neovim

Neovim plugin for Google Gemini AI with File Search RAG capabilities. A Lua port of the Obsidian Gemini Helper plugin.

## Features

- **Streaming Chat Interface**: Real-time response streaming with Gemini API
- **Function Calling**: AI can directly execute workspace operations (9 tools)
- **Multiple Model Support**: Gemini 3 Flash/Pro Preview, 2.5 Flash Lite
- **Web Search**: Search the web for up-to-date information using Google Search
- **Slash Commands**: Custom command templates with variable expansion
- **File Attachments**: Support for images and text files
- **Chat History**: Auto-saves conversations to Markdown files
- **Semantic Search (RAG)**: Semantic search using Google's File Search API with stores managed by [ragujuary](https://github.com/takeshy/ragujuary)
- **Safe Editing**: Propose-edit workflow with apply/discard confirmation
- **Local Search**: Filename and content-based search with relevance scoring

## Requirements

- Neovim 0.8+
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- Google AI API key

## Installation

### Using lazy.nvim

```lua
{
  "takeshy/nvim-gemini-helper",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("gemini_helper").setup({
      api_key = vim.env.GOOGLE_API_KEY, -- or set via :GeminiSetApiKey
      model = "gemini-3-flash-preview", -- Default model
      workspace = vim.fn.getcwd(),
      allow_write = false, -- Enable to allow file modifications
      rag_enabled = false, -- Enable for semantic search features
      rag_store_name = nil, -- Store name created by ragujuary (e.g. "fileSearchStores/your-store")
    })
  end,
}
```

### Using packer.nvim

```lua
use {
  "takeshy/nvim-gemini-helper",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("gemini_helper").setup({
      api_key = vim.env.GOOGLE_API_KEY,
    })
  end,
}
```

## Setup

1. Get a Google AI API key from [Google AI Studio](https://aistudio.google.com/)

2. Set your API key:
   ```vim
   :GeminiSetApiKey YOUR_API_KEY
   ```

   Or set it in your config:
   ```lua
   require("gemini_helper").setup({
     api_key = "YOUR_API_KEY",
   })
   ```

   Or use an environment variable:
   ```bash
   export GOOGLE_API_KEY="YOUR_API_KEY"
   ```

## Commands

| Command | Description |
|---------|-------------|
| `:GeminiChat` | Open Gemini chat window |
| `:GeminiNewChat` | Start a new chat session |
| `:GeminiHistory` | Browse and load chat history |
| `:GeminiSettings` | Show current settings |
| `:GeminiSetApiKey <key>` | Set Google API key |
| `:GeminiToggleWrite` | Toggle write permissions for AI |
| `:GeminiTest` | Test API connection |
| `:GeminiWebSearch` | Enable Web Search for messages |
| `:GeminiSearchNone` | Disable search |
| `:GeminiSlashCommands` | Show slash command picker |
| `:GeminiAddSlashCommand <name> <template>` | Add a slash command |

## Default Keymaps

| Keymap | Description |
|--------|-------------|
| `<leader>gc` | Open Gemini chat |
| `<leader>gn` | New Gemini chat |
| `<leader>gh` | Show chat history |
| `<leader>gs` | Show settings |
| `<leader>g/` | Show slash commands |
| `<leader>gc` (visual) | Open chat with selection |

### In Chat Window

| Keymap | Description |
|--------|-------------|
| `<Enter>` | Send message |
| `<S-Enter>` | Insert newline |
| `<C-c>` | Stop generation |
| `<C-q>` | Close (insert mode) |
| `q` or `<Esc>` | Close (normal mode) |

## Configuration

```lua
require("gemini_helper").setup({
  -- API Settings
  api_key = "",  -- Google AI API key (required)
  model = "gemini-3-flash-preview",  -- Model to use

  -- Workspace
  workspace = vim.fn.getcwd(),  -- Root directory for file operations

  -- Chat
  chats_folder = vim.fn.stdpath("data") .. "/gemini_helper/chats",
  system_prompt = "",  -- Custom system instructions

  -- Permissions
  allow_write = false,  -- Allow AI to modify files

  -- Search Settings
  search_setting = nil,  -- nil=None, "__websearch__"=Web Search, or store name for semantic search

  -- Semantic Search (RAG via ragujuary)
  rag_enabled = false,
  rag_store_name = nil, -- e.g. "fileSearchStores/your-store"

  -- Slash Commands
  slash_commands = {},  -- Custom command templates

  -- UI
  chat_width = 80,
  chat_height = 20,

  -- Debug
  debug_mode = false,
})
```

## Available Tools

The AI can use these tools to interact with your workspace:

### Read Operations (Always Available)

| Tool | Description |
|------|-------------|
| `read_note` | Read contents of a file |
| `search_notes` | Search by filename or content |
| `list_notes` | List files in a folder |
| `list_folders` | List all folders |
| `get_active_note_info` | Get info about current buffer |

### Write Operations (Require `allow_write = true`)

| Tool | Description |
|------|-------------|
| `create_note` | Create a new file |
| `create_folder` | Create a new folder |
| `rename_note` | Rename/move a file |
| `update_note` | Update a note's content |
| `write_to_buffer` | Write directly to current buffer (works with unsaved buffers) |

## Web Search

Enable Web Search to let the AI search the internet for up-to-date information.

```vim
:GeminiWebSearch
```

When enabled, the AI will use Google Search to find relevant information before responding. Note that Web Search cannot be used together with function calling tools or semantic search.

## Slash Commands

Create custom command templates that can be quickly invoked with `/commandname`.

### Adding Slash Commands

Via command:
```vim
:GeminiAddSlashCommand translate Translate the following to English: {selection}
```

Via setup:
```lua
require("gemini_helper").setup({
  slash_commands = {
    {
      name = "translate",
      prompt_template = "Translate the following to English: {selection}",
      description = "Translate selection to English",
    },
    {
      name = "explain",
      prompt_template = "Explain this code:\n{selection}",
      description = "Explain selected code",
      model = "gemini-3-pro-preview",  -- Use specific model
    },
    {
      name = "search",
      prompt_template = "Search for information about: {selection}",
      search_setting = "__websearch__",  -- Enable Web Search
    },
  },
})
```

### Available Variables

| Variable | Description |
|----------|-------------|
| `{selection}` | Current visual selection |
| `{file}` | Current file name |
| `{filepath}` | Full file path |
| `{line}` | Current line content |

### Using Slash Commands

1. Select text in visual mode (optional)
2. Open chat with `<leader>gc`
3. Type `/commandname` and press Enter

Or use the picker: `<leader>g/` or `:GeminiSlashCommands`

## Semantic Search (RAG)

Semantic search allows the AI to find relevant context from your files using Google's File Search API.

### Setup Semantic Search

1. Install [ragujuary](https://github.com/takeshy/ragujuary) CLI tool
2. Create and manage your File Search store with ragujuary:
   ```bash
   ragujuary upload ./docs -s my-store
   ```
3. Configure the plugin with your store name:
   ```lua
   require("gemini_helper").setup({
     rag_enabled = true,
     rag_store_name = "fileSearchStores/my-store",
   })
   ```

### How It Works

- Files are managed by ragujuary (upload, sync, delete)
- This plugin uses the store for semantic search during chat
- AI can query the store for relevant context when answering questions
- Supports various file formats: .txt, .md, .pdf, .doc, .docx, code files, etc.

## Chat History

Chat history is saved as Markdown files in `~/.local/share/nvim/gemini_helper/chats/`.

Format:
```markdown
---
title: "Chat title..."
createdAt: 1702841234567
updatedAt: 1702841240000
---

# Chat title...

*Created: 2024-01-01 12:00*

---

## **You** (12:00:00)

Your message here...

---

## **Gemini** (12:00:05)

> Tools: read_note, search_notes

AI response here...

---
```

## Available Models

| Model | Description |
|-------|-------------|
| `gemini-3-flash-preview` | Latest fast model with 1M context (default, recommended) |
| `gemini-3-pro-preview` | Latest flagship model with 1M context, best performance |
| `gemini-2.5-flash-lite` | Lightweight flash model |

## License

MIT

## Credits

Based on [obsidian-gemini-helper](https://github.com/your-username/obsidian-gemini-helper).
