# Gemini Helper for Neovim

Neovim plugin for Google Gemini AI with File Search RAG capabilities. A Lua port of the Obsidian Gemini Helper plugin.

## Features

- **Streaming Chat Interface**: Real-time response streaming with Gemini API
- **Function Calling**: AI can directly execute workspace operations (9 tools)
- **Multiple Model Support**: Gemini 2.5 Pro/Flash, 3 Pro Preview
- **File Attachments**: Support for images and text files
- **Chat History**: Auto-saves conversations to Markdown files
- **RAG (File Search)**: Semantic search using Google's File Search API with stores managed by [ragujuary](https://github.com/takeshy/ragujuary)
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
      model = "gemini-2.5-flash",
      workspace = vim.fn.getcwd(),
      allow_write = false, -- Enable to allow file modifications
      rag_enabled = false, -- Enable for RAG features
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

## Default Keymaps

| Keymap | Description |
|--------|-------------|
| `<leader>gc` | Open Gemini chat |
| `<leader>gn` | New Gemini chat |
| `<leader>gh` | Show chat history |
| `<leader>gs` | Show settings |

### In Chat Window

| Keymap | Description |
|--------|-------------|
| `<Enter>` | Send message |
| `<C-c>` | Stop generation |
| `q` or `<Esc>` | Close chat window |

## Configuration

```lua
require("gemini_helper").setup({
  -- API Settings
  api_key = "",  -- Google AI API key (required)
  model = "gemini-2.5-flash",  -- Model to use

  -- Workspace
  workspace = vim.fn.getcwd(),  -- Root directory for file operations

  -- Chat
  chats_folder = vim.fn.stdpath("data") .. "/gemini_helper/chats",
  system_prompt = "",  -- Custom system instructions

  -- Permissions
  allow_write = false,  -- Allow AI to modify files

  -- RAG (Retrieval Augmented Generation via ragujuary)
  rag_enabled = false,
  rag_store_name = nil, -- e.g. "fileSearchStores/your-store"

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

## RAG (Retrieval Augmented Generation)

RAG allows the AI to semantically search your files for relevant context using Google's File Search API.

### Setup RAG

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

- `gemini-3-pro-preview` - Latest and most capable model
- `gemini-2.5-flash` (default) - Fast and cost-effective
- `gemini-2.5-pro` - More capable

## License

MIT

## Credits

Based on [obsidian-gemini-helper](https://github.com/your-username/obsidian-gemini-helper).
