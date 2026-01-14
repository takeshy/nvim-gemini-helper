# Gemini Helper for Neovim

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/takeshy/nvim-gemini-helper)

Neovim plugin for Google Gemini AI with File Search RAG capabilities. A Lua port of the Obsidian Gemini Helper plugin.

![Gemini Helper Screenshot](gemini_helper.png)

## Features

- **Streaming Chat Interface**: Real-time response streaming with Gemini API
- **CLI Provider Support**: Use Gemini CLI, Claude CLI, or Codex CLI as alternative backends
- **Function Calling**: AI can directly execute workspace operations (9 tools)
- **Multiple Model Support**: Gemini 3 Flash/Pro Preview, 2.5 Flash Lite, and CLI models
- **Web Search**: Search the web for up-to-date information using Google Search
- **Bang Commands**: Custom command templates triggered with `!commandname`
- **File Attachments**: Support for images and text files
- **Chat History**: Auto-saves conversations to Markdown files
- **Semantic Search (RAG)**: Semantic search using Google's File Search API with stores managed by [ragujuary](https://github.com/takeshy/ragujuary)
- **Safe Editing**: Propose-edit workflow with apply/discard confirmation
- **Local Search**: Filename and content-based search with relevance scoring
- **Auto Copy Response**: Automatically copy AI responses to `*` register

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
      search_setting = nil, -- Default: nil, "__websearch__", store name, or array
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
| `:GeminiBangCommands` | Show bang command picker |
| `:GeminiAddBangCommand <name> <template>` | Add a bang command |
| `:GeminiDebug` | Toggle debug mode |
| `:GeminiSetApiPlan <paid\|free>` | Set API plan (affects available models) |
| `:GeminiVerifyGeminiCli` | Verify Gemini CLI installation |
| `:GeminiVerifyClaudeCli` | Verify Claude CLI installation |
| `:GeminiVerifyCodexCli` | Verify Codex CLI installation |

## Default Keymaps

| Keymap | Description |
|--------|-------------|
| `<leader>gc` | Open Gemini chat |
| `<leader>gn` | New Gemini chat |
| `<leader>gh` | Show chat history |
| `<leader>gs` | Show settings |
| `<leader>g/` | Show bang commands |
| `<leader>gc` (visual) | Open chat with selection |
| `<C-\>` | Toggle focus between chat and buffer |

### In Chat Window

| Keymap | Description |
|--------|-------------|
| `<Enter>` (normal) | Send message |
| `<Enter>` (insert) | Insert newline / Confirm completion |
| `<C-s>` | Send message (insert/normal) |
| `<Tab>` | Next completion item |
| `<S-Tab>` | Previous completion item |
| `!` | Trigger bang command completion (at line 1) |
| `?` | Open settings modal (at line 1) |
| `<C-u>` | Scroll response area up (half page) |
| `<C-d>` | Scroll response area down (half page) |
| `<C-\>` | Switch to original buffer |
| `<C-c>` | Stop generation |
| `<C-q>` | Close (insert mode) |
| `q` or `<Esc>` | Close (normal mode) |

### Input Area

- Default height: 2 lines
- Automatically expands up to 10 lines based on content
- When opening with selection, an empty line is added at top for `!` commands
- Settings bar below input shows current model and search settings (with `*` if overridden)
- Type `?` at the beginning of line 1 to open settings modal

### Settings Modal (`?`)

Press `?` at the beginning of line 1 to open the settings modal:

1. **Model selection**: Choose from available models (based on API plan)
2. **Search settings**:
   - Off (clear all)
   - Web Search (exclusive with RAG)
   - Current RAG store (shown with `[x]` if enabled)
   - Change RAG store (select from available stores or enter manually)
3. **Tool mode**: Automatically set based on model/search settings, can be overridden
   - `all`: All tools available
   - `noSearch`: Exclude search tools (when RAG handles search)
   - `none`: No tools (CLI models, Web Search, Gemma models)

Settings changed via modal persist until Neovim exits. Web Search and RAG are mutually exclusive.

## Configuration

```lua
require("gemini_helper").setup({
  -- API Settings
  api_key = "",  -- Google AI API key (required)
  api_plan = "paid",  -- "paid" or "free" (affects available models)
  model = "gemini-3-flash-preview",  -- Model to use

  -- Workspace
  workspace = vim.fn.getcwd(),  -- Root directory for file operations

  -- Chat
  chats_folder = vim.fn.stdpath("data") .. "/gemini_helper/chats",
  system_prompt = "",  -- Custom system instructions

  -- Permissions
  allow_write = false,  -- Allow AI to modify files

  -- Search Settings (also used for RAG via ragujuary)
  search_setting = nil,  -- nil=None, "__websearch__"=Web Search, store name, or array

  -- Bang Commands
  commands = {},  -- Custom command templates

  -- UI
  chat_width = 80,
  chat_height = 20,

  -- Auto copy
  auto_copy_response = true,  -- Auto copy AI response to * register

  -- Debug
  debug_mode = false,
})
```

## Tool Modes

The plugin automatically adjusts which tools are available based on your settings:

| Mode | Tools Available | When Active |
|------|----------------|-------------|
| `all` | All tools (read + write if allowed) | Default mode |
| `noSearch` | Excludes search_notes, list_notes, list_folders | When RAG is enabled (RAG handles search) |
| `off` | No tools | CLI models, Web Search, or Gemma models |

The settings bar shows the current tool mode: `Tools:all`, `Tools:noSearch`, or `Tools:off`.

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

When enabled, the AI will use Google Search to find relevant information before responding.

**Note**: Web Search and RAG (Semantic Search) are mutually exclusive. Enabling one will disable the other. Web Search also disables function calling tools.

## Bang Commands

Create custom command templates that can be quickly invoked with `!commandname`.

### Adding Bang Commands

Via command:
```vim
:GeminiAddBangCommand translate Translate the following to English:
```

Via setup:
```lua
require("gemini_helper").setup({
  commands = {
    {
      name = "translate",
      prompt_template = "Translate the following to English:",
      description = "Translate to English",
    },
    {
      name = "explain",
      prompt_template = "Explain this code:",
      description = "Explain selected code",
      model = "gemini-3-pro-preview",  -- Override model for this command
    },
    {
      name = "search",
      prompt_template = "Search for information about:",
      description = "Web search",
      search_setting = "__websearch__",  -- Enable Web Search
    },
    {
      name = "docs",
      prompt_template = "Find relevant documentation:",
      description = "Search multiple RAG stores",
      search_setting = { "docs-store", "api-store" },  -- Multiple RAG stores
    },
  },
})
```

### Using Bang Commands

1. Select text in visual mode (optional)
2. Open chat with `<leader>gc`
3. Type `!` at the beginning of line 1 to trigger completion
4. Use `Tab`/`Shift-Tab` to navigate, `Enter` to confirm
5. The command's `prompt_template` replaces the `!command`
6. Selection text (if any) appears below for context

Or use the picker: `<leader>g/` or `:GeminiBangCommands`

## Semantic Search (RAG)

Semantic search allows the AI to find relevant context from your files using Google's File Search API.

**Note**: RAG and Web Search are mutually exclusive. You can use either RAG stores or Web Search, but not both at the same time.

### Setup Semantic Search

1. Install [ragujuary](https://github.com/takeshy/ragujuary) CLI tool
2. Create and manage your File Search store with ragujuary:
   ```bash
   ragujuary upload ./docs -s my-store
   ```
3. Configure the plugin with your store name:
   ```lua
   require("gemini_helper").setup({
     search_setting = "my-store",  -- Single store
     -- or multiple: search_setting = { "docs-store", "api-store" }
   })
   ```

Or use the settings modal (`?` in chat) to set RAG stores dynamically (comma-separated for multiple stores).

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

### Paid Plan Models

| Model | Description |
|-------|-------------|
| `gemini-3-flash-preview` | Latest fast model with 1M context (default, recommended) |
| `gemini-3-pro-preview` | Latest flagship model with 1M context, best performance |
| `gemini-2.5-flash-lite` | Lightweight flash model |

### Free Plan Models

| Model | Description |
|-------|-------------|
| `gemini-2.5-flash` | Free tier fast model |
| `gemini-2.5-flash-lite` | Free tier lightweight model |
| `gemini-3-flash-preview` | Free tier preview model |
| `gemma-3-27b-it` | Gemma 3 27B (no function calling) |
| `gemma-3-12b-it` | Gemma 3 12B (no function calling) |
| `gemma-3-4b-it` | Gemma 3 4B (no function calling) |

### CLI Models

CLI models require the respective CLI tool to be installed and verified.

| Model | Description |
|-------|-------------|
| `gemini-cli` | Google Gemini via command line (requires Google account) |
| `claude-cli` | Anthropic Claude via command line (requires Anthropic account) |
| `codex-cli` | OpenAI Codex via command line (requires OpenAI account) |

## CLI Providers

Use CLI-based AI backends without requiring API keys. CLI models support session resumption (Claude/Codex) for maintaining conversation context.

### Setup

1. Install the CLI tool:
   ```bash
   # Gemini CLI
   npm install -g @google/gemini-cli

   # Claude CLI
   npm install -g @anthropic-ai/claude-code

   # Codex CLI
   npm install -g @openai/codex
   ```

2. Verify the installation:
   ```vim
   :GeminiVerifyClaudeCli
   ```

3. Select the CLI model in the settings modal (`?` in chat)

### Notes

- CLI models don't support Web Search or RAG
- Claude CLI and Codex CLI support session resumption
- No API key required (uses CLI authentication)
- Verified CLI models appear in the model selector

## License

MIT

## Credits

Based on [obsidian-gemini-helper](https://github.com/your-username/obsidian-gemini-helper).
