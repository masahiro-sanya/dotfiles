# dotfiles

macOS 環境の設定ファイル群。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `shell/` | zsh 設定 (.zshrc, .zprofile, .zshenv) |
| `git/` | .gitconfig, .gitignore_global |
| `terminal/wezterm/` | WezTerm 設定 |
| `nvim/` | Neovim (LazyVim) 設定 |
| `karabiner/` | Karabiner-Elements 設定 (HHKB キーリマップ) |
| `editor/vscode/` | VS Code 設定 |
| `claude/` | Claude Code 設定 (settings, hooks, commands, skills) |
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
- Slack MCP は `mcp-servers.sh` が公式プラグイン `slack@claude-plugins-official` を自動インストール。Claude Code 起動後、初回接続でブラウザ OAuth（light-inc-com ワークスペース）→ 認証後に再起動で有効化
- light-skills のプラグイン（palmu-api-doc など）は light-skills リポ側で導入
- notion MCP は初回接続時にブラウザで OAuth 認証

Karabiner-Elements の初回起動時:
- システム設定 → プライバシーとセキュリティ → ドライバ機能拡張を許可
- システム設定 → プライバシーとセキュリティ → 入力監視で karabiner_grabber を許可

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
