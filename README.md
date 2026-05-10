# dotfiles

macOS 環境の設定ファイル群。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `shell/` | zsh 設定 (.zshrc, .zprofile, .zshenv) |
| `git/` | .gitconfig, .gitignore_global |
| `terminal/wezterm/` | WezTerm 設定 |
| `nvim/` | Neovim (LazyVim) 設定 |
| `editor/vscode/` | VS Code 設定 |
| `claude/` | Claude Code 設定 (settings, hooks, commands) |
| `mise/` | mise (ランタイムバージョン管理) 設定 |
| `Brewfile` | Homebrew パッケージ一覧 |

## セットアップ（新PC）

### ワンライナー

```bash
curl -fsSL https://raw.githubusercontent.com/masahiro-sanya/dotfiles/main/bootstrap.sh | bash
```

これで以下を一括実行: Xcode CLT 確認 → Homebrew → dotfiles clone → Prezto → symlink → `brew bundle` → anyenv + 各ランタイム → `mise install` → Claude Code CLI インストール → MCP サーバ登録。

### 残りの手動ステップ（対話/認証が必要なもの）

```bash
gh auth login
gcloud auth login && gcloud auth application-default login
claude  # 初回起動でブラウザログイン
```

Claude Code のマシン固有設定:
- `~/.claude/settings.local.json` を旧マシンからコピー（plugin/permission の機械固有設定）
- Claude Code 起動後、`/plugin` から marketplace プラグインを導入（Slack / palmu-api-doc / Google Drive など）
- notion MCP は初回接続時にブラウザで OAuth 認証

### 個別実行したい場合

```bash
make link    # シンボリックリンクのみ
make brew    # brew bundle のみ
make all     # link + brew + mise install
```

## 設定の更新

現在の環境から設定をダンプするには：

```bash
make dump
```

Brewfile、mise バージョン一覧が更新されます。
