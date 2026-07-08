#
# Executes commands at the start of an interactive session.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

# Source Prezto.
if [[ -s "${ZDOTDIR:-$HOME}/.zprezto/init.zsh" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"
fi

# Customize to your needs...
export PATH="$HOME/.anyenv/bin:$PATH"
eval "$(anyenv init - zsh)"

# The next line updates PATH for the Google Cloud SDK.
if [ -f "/opt/homebrew/share/google-cloud-sdk/path.zsh.inc" ]; then . "/opt/homebrew/share/google-cloud-sdk/path.zsh.inc"
elif [ -f "$HOME/google-cloud-sdk/path.zsh.inc" ]; then . "$HOME/google-cloud-sdk/path.zsh.inc"; fi

# The next line enables shell command completion for gcloud.
if [ -f "/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc" ]; then . "/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc"
elif [ -f "$HOME/google-cloud-sdk/completion.zsh.inc" ]; then . "$HOME/google-cloud-sdk/completion.zsh.inc"; fi
export PATH="/usr/local/opt/openjdk/bin:$PATH"
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH"


eval "$(direnv hook zsh)"
export PATH="$PATH:$(go env GOPATH)/bin"
eval "$(/opt/homebrew/bin/mise activate zsh)"

eval "$(anyenv init -)"
# Claude Code: auto compact window size
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000

# fzf: Ctrl-R (history), Ctrl-T (files), Alt-C (dirs)
if command -v fzf >/dev/null 2>&1; then
  source <(fzf --zsh)
  if command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
  fi
fi

# bat: syntax-highlighted man pages
if command -v bat >/dev/null 2>&1; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT="-c"
fi

# zoxide: smarter cd (use `z <query>` to jump to frecent dirs)
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# eza: modern ls with git integration
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first'
  alias ll='eza -l --git --group-directories-first'
  alias la='eza -la --git --group-directories-first'
  alias lt='eza --tree --level=2 --group-directories-first'
fi

# --- wezterm: カレントディレクトリを OSC 7 で通知 ---
# prezto の terminal モジュールは Apple_Terminal 限定でしか OSC 7 を出さない。
# wezterm でタブ名にリポ名を出すには pane の cwd が要るので、自前で補う。
# cw は `cd <repo> && claude` なので、claude 起動直前の cd(chpwd) で repo が通知される。
if [[ -n "$WEZTERM_PANE" ]]; then
  autoload -Uz add-zsh-hook
  _wezterm_osc7() { printf '\e]7;file://%s%s\a' "${HOST}" "${PWD// /%20}"; }
  add-zsh-hook chpwd _wezterm_osc7
  add-zsh-hook precmd _wezterm_osc7
  _wezterm_osc7
fi

# --- Claude Code: 個別リポ cwd 起動 ---
# ~/src・~/src/palmu（親ディレクトリ）で claude を起動すると memory や
# プロジェクト設定が親側に分散するため、個別リポでの起動を習慣化する。

# cw 用: ~/src/*/ と ~/src/palmu/*/ の git リポ一覧（フルパス）
_cw_repos() {
  local base dir
  local -a found
  found=()
  for base in "$HOME/src" "$HOME/src/palmu"; do
    [[ -d "$base" ]] || continue
    for dir in "$base"/*/; do
      [[ -e "${dir}.git" ]] && found+=("${dir%/}")
    done
  done
  print -l -- "${found[@]}"
}

# cw [リポ名]: リポジトリを選んで cd + claude 起動
# 引数あり: 名前一致（完全一致 → 前方一致）で cd。引数なし: fzf（無ければ select）で選択
cw() {
  local repo
  local -a repos matches
  repos=(${(f)"$(_cw_repos)"})
  if (( ${#repos[@]} == 0 )); then
    echo "cw: git リポが見つかりません (~/src, ~/src/palmu)" >&2
    return 1
  fi
  if [[ -n "$1" ]]; then
    matches=(${(M)repos:#*/$1})                            # 完全一致
    (( ${#matches[@]} == 0 )) && matches=(${(M)repos:#*/$1*})  # 前方一致
    if (( ${#matches[@]} == 0 )); then
      echo "cw: リポが見つかりません: $1" >&2
      return 1
    fi
    repo="${matches[1]}"
  elif command -v fzf >/dev/null 2>&1; then
    repo="$(print -l -- "${repos[@]}" | fzf --prompt='repo> ')" || return 1
  else
    local PS3='repo> '
    select repo in "${repos[@]}"; do
      [[ -n "$repo" ]] && break
    done
    [[ -n "$repo" ]] || return 1
  fi
  cd "$repo" && command claude
}

# cw のリポ名補完
_cw() {
  local -a names
  local repo
  for repo in ${(f)"$(_cw_repos)"}; do
    names+=("${repo:t}")
  done
  compadd -- "${names[@]}"
}
command -v compdef >/dev/null 2>&1 && compdef _cw cw

# claude ラッパー: 親ディレクトリ（~/src / ~/src/palmu そのもの）での起動に警告
claude() {
  local ans
  case "$PWD" in
    "$HOME/src"|"$HOME/src/palmu")
      echo "claude: $PWD は親ディレクトリです。memory/設定が分散するため個別リポでの起動を推奨します（cw <リポ名> が使えます）。" >&2
      printf 'このまま起動しますか？ [y/N] ' >&2
      read -r ans
      case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "claude: 中止しました" >&2; return 1 ;;
      esac
      ;;
  esac
  command claude "$@"
}

# サプライチェーン攻撃対策: pip を Flatt 管理レジストリ経由に
export PIP_INDEX_URL=https://pypi.flatt.tech/simple/
export PATH="$HOME/.local/bin:$PATH"

# Vite+ bin (https://viteplus.dev)
. "$HOME/.vite-plus/env"
