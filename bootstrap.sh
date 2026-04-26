#!/bin/bash
set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/masahiro-sanya/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/src/dotfiles}"

NODE_VERSION="20.19.5"
PYTHON_VERSION="3.11.0"
RUBY_VERSION="3.4.6"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
step() { echo -e "\n${GREEN}==>${NC} $1"; }
note() { echo -e "${YELLOW}[note]${NC} $1"; }

# 1. Xcode CLT (required by brew, git)
if ! xcode-select -p &>/dev/null; then
  step "Installing Xcode Command Line Tools (GUI prompt)"
  xcode-select --install || true
  echo "Re-run this script after CLT install completes."
  exit 0
fi

# 2. Homebrew
if ! command -v brew &>/dev/null; then
  step "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x /usr/local/bin/brew ]   && eval "$(/usr/local/bin/brew shellenv)"

# 3. Clone dotfiles
if [ ! -d "$DOTFILES_DIR" ]; then
  step "Cloning dotfiles into $DOTFILES_DIR"
  mkdir -p "$(dirname "$DOTFILES_DIR")"
  git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

# 4. Prezto (.zshrc が依存)
if [ ! -d "$HOME/.zprezto" ]; then
  step "Installing Prezto"
  git clone --recursive https://github.com/sorin-ionescu/prezto.git "$HOME/.zprezto"
fi

# 5. Symlinks
step "Linking config files"
bash "$DOTFILES_DIR/setup.sh"

# 6. Brew bundle
step "Installing Brewfile packages"
brew bundle --file="$DOTFILES_DIR/Brewfile"

# 7. anyenv + ランタイム
step "Setting up anyenv runtimes"
export PATH="$HOME/.anyenv/bin:$PATH"
if [ ! -d "$HOME/.config/anyenv/anyenv-install" ]; then
  yes | anyenv install --init || true
fi
eval "$(anyenv init -)"
for plugin in nodenv pyenv rbenv; do
  [ -d "$HOME/.anyenv/envs/$plugin" ] || anyenv install "$plugin" || true
done
eval "$(anyenv init -)"

nodenv install -s "$NODE_VERSION"   && nodenv global "$NODE_VERSION"
pyenv  install -s "$PYTHON_VERSION" && pyenv  global "$PYTHON_VERSION"
rbenv  install -s "$RUBY_VERSION"   && rbenv  global "$RUBY_VERSION"

# 8. mise
step "Installing mise tools"
eval "$(mise activate bash)"
mise install -y

# 9. 残り（手動）
step "Bootstrap complete"
cat <<'EOF'

残りの手動ステップ:
  1. gh auth login
  2. gcloud auth login && gcloud auth application-default login
  3. ~/.claude/settings.local.json を旧マシンからコピー（plugin/permission/MCP）
  4. claude mcp add ...（MCPサーバ再登録 / 旧マシンの ~/.claude.json 参照）

新シェルを開く: exec zsh -l
EOF
