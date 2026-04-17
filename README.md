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

## セットアップ

### 1. Homebrew をインストール

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. リポジトリをクローン

```bash
git clone https://github.com/masahiro-sanya/dotfiles.git ~/src/dotfiles
cd ~/src/dotfiles
```

### 3. シンボリックリンクを作成

```bash
bash setup.sh
```

各設定ファイルのシンボリックリンクが作成されます。既存ファイルは `backup/` に自動バックアップされます。

git user.email が未設定の場合、対話的に入力を求められます。

### 4. パッケージをインストール

```bash
brew bundle --file=~/src/dotfiles/Brewfile
```

### 5. ランタイムをセットアップ

```bash
# anyenv
anyenv install --init
anyenv install nodenv && anyenv install pyenv && anyenv install rbenv

# 各言語
nodenv install 20.19.5 && nodenv global 20.19.5
pyenv install 3.11.0 && pyenv global 3.11.0
rbenv install 3.4.6 && rbenv global 3.4.6

# mise
mise install
```

### 6. 認証

```bash
gh auth login
gcloud auth login && gcloud auth application-default login
```

### 7. Claude Code (任意)

`claude/settings.local.json` はマシン固有の設定（許可ルール・プラグイン等）のため、手動で設定してください。

## 設定の更新

現在の環境から設定をダンプするには：

```bash
make dump
```

Brewfile、mise バージョン一覧が更新されます。
