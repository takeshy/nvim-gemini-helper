# Gemini Helper for Neovim

Google Gemini AIをNeovimで使うためのプラグインです。RAG（File Search）機能も搭載しています。Obsidian Gemini HelperプラグインのLua移植版です。

## 機能

- **ストリーミングチャット**: Gemini APIでリアルタイム応答
- **Function Calling**: AIがワークスペースを直接操作（9種類のツール）
- **複数モデル対応**: Gemini 3 Flash/Pro Preview、2.5 Flash Lite
- **Web Search**: Google検索で最新情報を取得
- **スラッシュコマンド**: 変数展開付きのカスタムコマンドテンプレート
- **ファイル添付**: 画像やテキストファイルの添付
- **チャット履歴**: 会話をMarkdownファイルで自動保存
- **セマンティック検索（RAG）**: [ragujuary](https://github.com/takeshy/ragujuary)で管理されたストアを使った意味検索
- **Safe Editing**: 提案→確認→適用の安全な編集ワークフロー
- **ローカル検索**: ファイル名・コンテンツ検索（関連度スコア付き）

## 必要条件

- Neovim 0.8以上
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- Google AI APIキー

## インストール

### lazy.nvim

```lua
{
  "takeshy/nvim-gemini-helper",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("gemini_helper").setup({
      api_key = vim.env.GOOGLE_API_KEY, -- または :GeminiSetApiKey で設定
      model = "gemini-3-flash-preview", -- デフォルトモデル
      workspace = vim.fn.getcwd(),
      allow_write = false, -- ファイル編集を許可する場合はtrue
      rag_enabled = false, -- セマンティック検索を使う場合はtrue
      rag_store_name = nil, -- ragujuaryで作成したストア名（例: "fileSearchStores/my-store"）
    })
  end,
}
```

### packer.nvim

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

## セットアップ

1. [Google AI Studio](https://aistudio.google.com/) でAPIキーを取得

2. APIキーを設定:
   ```vim
   :GeminiSetApiKey YOUR_API_KEY
   ```

   または設定ファイルで:
   ```lua
   require("gemini_helper").setup({
     api_key = "YOUR_API_KEY",
   })
   ```

   または環境変数で:
   ```bash
   export GOOGLE_API_KEY="YOUR_API_KEY"
   ```

## コマンド一覧

| コマンド | 説明 |
|---------|------|
| `:GeminiChat` | チャットウィンドウを開く |
| `:GeminiNewChat` | 新しいチャットを開始 |
| `:GeminiHistory` | チャット履歴を表示・選択 |
| `:GeminiSettings` | 現在の設定を表示 |
| `:GeminiSetApiKey <key>` | APIキーを設定 |
| `:GeminiToggleWrite` | 書き込み権限を切り替え |
| `:GeminiTest` | API接続テスト |
| `:GeminiWebSearch` | Web検索を有効化 |
| `:GeminiSearchNone` | 検索を無効化 |
| `:GeminiSlashCommands` | スラッシュコマンドピッカーを表示 |
| `:GeminiAddSlashCommand <名前> <テンプレート>` | スラッシュコマンドを追加 |

## デフォルトキーマップ

| キーマップ | 説明 |
|-----------|------|
| `<leader>gc` | チャットを開く |
| `<leader>gn` | 新規チャット |
| `<leader>gh` | 履歴を表示 |
| `<leader>gs` | 設定を表示 |
| `<leader>g/` | スラッシュコマンドを表示 |
| `<leader>gc` (ビジュアル) | 選択テキストと共にチャットを開く |

### チャットウィンドウ内

| キーマップ | 説明 |
|-----------|------|
| `<Enter>` | メッセージ送信 |
| `<S-Enter>` | 改行を挿入 |
| `<C-c>` | 生成を停止 |
| `<C-q>` | 閉じる（インサートモード） |
| `q` または `<Esc>` | 閉じる（ノーマルモード） |

## 設定オプション

```lua
require("gemini_helper").setup({
  -- API設定
  api_key = "",  -- Google AI APIキー（必須）
  model = "gemini-3-flash-preview",  -- 使用するモデル

  -- ワークスペース
  workspace = vim.fn.getcwd(),  -- ファイル操作のルートディレクトリ

  -- チャット
  chats_folder = vim.fn.stdpath("data") .. "/gemini_helper/chats",
  system_prompt = "",  -- カスタムシステムプロンプト

  -- 権限
  allow_write = false,  -- AIによるファイル編集を許可

  -- 検索設定
  search_setting = nil,  -- nil=なし、"__websearch__"=Web検索、その他=セマンティック検索のストア名

  -- セマンティック検索（RAG - ragujuaryによる）
  rag_enabled = false,  -- セマンティック検索を有効化
  rag_store_name = nil, -- ragujuaryで作成したストア名（例: "fileSearchStores/my-store"）

  -- スラッシュコマンド
  slash_commands = {},  -- カスタムコマンドテンプレート

  -- UI
  chat_width = 80,  -- チャットウィンドウの幅
  chat_height = 20,  -- チャットウィンドウの高さ

  -- デバッグ
  debug_mode = false,
})
```

## 利用可能なツール

AIがワークスペースと対話するために使用できるツールです。

### 読み取り操作（常に利用可能）

| ツール | 説明 |
|--------|------|
| `read_note` | ファイルの内容を読み取る |
| `search_notes` | ファイル名またはコンテンツで検索 |
| `list_notes` | フォルダ内のファイル一覧 |
| `list_folders` | すべてのフォルダ一覧 |
| `get_active_note_info` | 現在のバッファの情報を取得 |

### 書き込み操作（`allow_write = true` が必要）

| ツール | 説明 |
|--------|------|
| `create_note` | 新しいファイルを作成 |
| `create_folder` | 新しいフォルダを作成 |
| `rename_note` | ファイルの名前変更/移動 |
| `update_note` | ノートの内容を更新 |
| `write_to_buffer` | 現在のバッファに直接書き込み（未保存バッファも対応） |

## Web Search

Web検索を有効にすると、AIがインターネットから最新情報を取得できます。

```vim
:GeminiWebSearch
```

有効にすると、AIは応答する前にGoogle検索で関連情報を探します。Web検索はFunction Callingツールやセマンティック検索とは同時に使用できません。

## スラッシュコマンド

`/コマンド名`で素早く呼び出せるカスタムコマンドテンプレートを作成できます。

### スラッシュコマンドの追加

コマンドで追加:
```vim
:GeminiAddSlashCommand translate 以下を英語に翻訳して: {selection}
```

設定ファイルで追加:
```lua
require("gemini_helper").setup({
  slash_commands = {
    {
      name = "translate",
      prompt_template = "以下を英語に翻訳して: {selection}",
      description = "選択テキストを英語に翻訳",
    },
    {
      name = "explain",
      prompt_template = "このコードを説明して:\n{selection}",
      description = "選択コードを説明",
      model = "gemini-3-pro-preview",  -- 特定のモデルを使用
    },
    {
      name = "search",
      prompt_template = "以下について調べて: {selection}",
      search_setting = "__websearch__",  -- Web検索を有効化
    },
  },
})
```

### 利用可能な変数

| 変数 | 説明 |
|------|------|
| `{selection}` | 現在のビジュアル選択 |
| `{file}` | 現在のファイル名 |
| `{filepath}` | フルファイルパス |
| `{line}` | 現在行の内容 |

### スラッシュコマンドの使用方法

1. ビジュアルモードでテキストを選択（任意）
2. `<leader>gc`でチャットを開く
3. `/コマンド名`と入力してEnter

またはピッカーを使用: `<leader>g/` または `:GeminiSlashCommands`

## セマンティック検索（RAG）

セマンティック検索を使用すると、AIがファイルから意味的に関連するコンテキストを取得できます。Google File Search APIを使用します。

### セマンティック検索のセットアップ

1. [ragujuary](https://github.com/takeshy/ragujuary) CLIツールをインストール

2. ragujuaryでFile Searchストアを作成・管理:
   ```bash
   ragujuary upload ./docs -s my-store
   ```

3. プラグインにストア名を設定:
   ```lua
   require("gemini_helper").setup({
     rag_enabled = true,
     rag_store_name = "fileSearchStores/my-store",
   })
   ```

### 仕組み

- ファイルの管理（アップロード、同期、削除）はragujuaryで行う
- このプラグインはチャット時にストアを使ってセマンティック検索を実行
- AIが質問に答える際にストアから関連コンテキストを取得
- 対応フォーマット: .txt, .md, .pdf, .doc, .docx, コードファイルなど

### セマンティック検索の使用例

AIに聞くことができます：
- 「このプロジェクトについて教えて」（関連ファイルを検索）
- 「ドキュメントからXXXについて調べて」
- 「コードベースでYYYはどう実装されている？」

## チャット履歴

チャット履歴は`~/.local/share/nvim/gemini_helper/chats/`にMarkdownファイルとして保存されます。

形式:
```markdown
---
title: "チャットのタイトル..."
createdAt: 1702841234567
updatedAt: 1702841240000
---

# チャットのタイトル...

*Created: 2024-01-01 12:00*

---

## **You** (12:00:00)

あなたのメッセージ...

---

## **Gemini** (12:00:05)

> Tools: read_note, search_notes

AIの応答...

---
```

## 利用可能なモデル

| モデル | 説明 |
|--------|------|
| `gemini-3-flash-preview` | 最新の高速モデル、1Mコンテキスト（デフォルト、推奨） |
| `gemini-3-pro-preview` | 最新のフラッグシップモデル、1Mコンテキスト、最高性能 |
| `gemini-2.5-flash-lite` | 軽量フラッシュモデル |

## 設定ファイル

設定は自動的に以下に保存されます：
```
~/.local/share/nvim/gemini_helper/settings.json
```

## トラブルシューティング

### APIキーエラー
```
Please set your Google API key first with :GeminiSetApiKey
```
→ `:GeminiSetApiKey YOUR_API_KEY` でAPIキーを設定

### plenary.nvimが見つからない
```
gemini_helper requires plenary.nvim
```
→ plenary.nvimをインストール

### RAGが動作しない
- ragujuaryでストアが正しく作成されているか確認
- `rag_store_name`の形式が正しいか確認（例: `fileSearchStores/my-store`）
- `rag_enabled = true`になっているか確認

## ライセンス

MIT

## クレジット

[obsidian-gemini-helper](https://github.com/your-username/obsidian-gemini-helper) をベースにしています。
