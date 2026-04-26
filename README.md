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

これで以下を一括実行: Xcode CLT 確認 → Homebrew → dotfiles clone → Prezto → symlink → `brew bundle` → anyenv + 各ランタイム → `mise install`。

### 残りの手動ステップ

```bash
gh auth login
gcloud auth login && gcloud auth application-default login
```

Claude Code のマシン固有設定:
- `~/.claude/settings.local.json` を旧マシンからコピー（plugin/permission/MCP）
- `claude mcp add ...` で MCP サーバ再登録（旧マシンの `~/.claude.json` 参照）

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
