# Gemini Helper for Neovim

Google Gemini AIをNeovimで使うためのプラグインです。RAG（File Search）機能も搭載しています。Obsidian Gemini HelperプラグインのLua移植版です。

## 機能

- **ストリーミングチャット**: Gemini APIでリアルタイム応答
- **Function Calling**: AIがワークスペースを直接操作（9種類のツール）
- **複数モデル対応**: Gemini 3 Pro Preview、2.5 Pro/Flash
- **ファイル添付**: 画像やテキストファイルの添付（対応予定）
- **チャット履歴**: 会話をMarkdownファイルで自動保存
- **RAG（File Search）**: [ragujuary](https://github.com/takeshy/ragujuary)で管理されたストアを使ったセマンティック検索
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
  "your-username/nvim-gemini-helper",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("gemini_helper").setup({
      api_key = vim.env.GOOGLE_API_KEY, -- または :GeminiSetApiKey で設定
      model = "gemini-2.5-flash",
      workspace = vim.fn.getcwd(),
      allow_write = false, -- ファイル編集を許可する場合はtrue
      rag_enabled = false, -- RAG機能を使う場合はtrue
      rag_store_name = nil, -- ragujuaryで作成したストア名（例: "fileSearchStores/my-store"）
    })
  end,
}
```

### packer.nvim

```lua
use {
  "your-username/nvim-gemini-helper",
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

## デフォルトキーマップ

| キーマップ | 説明 |
|-----------|------|
| `<leader>gc` | チャットを開く |
| `<leader>gn` | 新規チャット |
| `<leader>gh` | 履歴を表示 |
| `<leader>gs` | 設定を表示 |

### チャットウィンドウ内

| キーマップ | 説明 |
|-----------|------|
| `<Enter>` | メッセージ送信 |
| `<C-c>` | 生成を停止 |
| `q` または `<Esc>` | ウィンドウを閉じる |

## 設定オプション

```lua
require("gemini_helper").setup({
  -- API設定
  api_key = "",  -- Google AI APIキー（必須）
  model = "gemini-2.5-flash",  -- 使用するモデル

  -- ワークスペース
  workspace = vim.fn.getcwd(),  -- ファイル操作のルートディレクトリ

  -- チャット
  chats_folder = vim.fn.stdpath("data") .. "/gemini_helper/chats",
  system_prompt = "",  -- カスタムシステムプロンプト

  -- 権限
  allow_write = false,  -- AIによるファイル編集を許可

  -- RAG（ragujuaryによる検索拡張生成）
  rag_enabled = false,  -- RAG機能を有効化
  rag_store_name = nil, -- ragujuaryで作成したストア名（例: "fileSearchStores/my-store"）

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

## RAG（検索拡張生成）

RAGを使用すると、AIがファイルからセマンティック検索で関連コンテキストを取得できます。Google File Search APIを使用します。

### RAGのセットアップ

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

### RAG使用例

AIに聞くことができます：
- 「このプロジェクトについて教えて」（RAGで関連ファイルを検索）
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
| `gemini-3-pro-preview` | 最新・最高性能モデル |
| `gemini-2.5-flash` | 高速でコスト効率が良い（デフォルト） |
| `gemini-2.5-pro` | より高機能 |

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
