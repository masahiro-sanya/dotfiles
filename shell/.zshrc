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

# anyenv init はファイル冒頭（14-15行目）で実行済み。ここでの再実行は重複なので削除した。
# 実測: 対話シェルの起動が約 0.25s 短縮される（anyenv init - 自体のコスト）
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
# stdout が端末でないときは出さない。`zsh -ilc '<cmd>'` の出力を読む外部ツール
# （一部の GUI アプリは `command -v claude` の結果を絶対パス扱いする）に対して、
# エスケープシーケンスが同じ行の先頭に混入してパースを壊すため。
if [[ -n "$WEZTERM_PANE" && -t 1 ]]; then
  autoload -Uz add-zsh-hook
  _wezterm_osc7() { printf '\e]7;file://%s%s\a' "${HOST}" "${PWD// /%20}"; }
  add-zsh-hook chpwd _wezterm_osc7
  add-zsh-hook precmd _wezterm_osc7
  _wezterm_osc7
fi

# --- Claude Code: 個別リポ cwd 起動 ---
# ~/src（親ディレクトリ）で claude を起動すると memory や
# プロジェクト設定が親側に分散するため、個別リポでの起動を習慣化する。
# マシン固有の親ディレクトリ（~/src/<group> など）は ~/.zshrc.local（git 管理外）で
# CW_EXTRA_BASES=("$HOME/src/<group>") のように配列で渡す。
typeset -a CW_EXTRA_BASES
CW_EXTRA_BASES=()
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"

# cw 用: ~/src/*/ と CW_EXTRA_BASES 配下の git リポ一覧（フルパス）
_cw_repos() {
  local base dir
  local -a found
  found=()
  for base in "$HOME/src" "${CW_EXTRA_BASES[@]}"; do
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
    echo "cw: git リポが見つかりません (~/src と CW_EXTRA_BASES)" >&2
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
  # claude ラッパー（下）を通して起動時の名前付けを効かせる
  cd "$repo" && claude
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

# claude ラッパー: 親ディレクトリ（~/src / CW_EXTRA_BASES そのもの）での起動に警告
# 端末から使うときだけ定義する。関数があると `command -v claude` がパスではなく
# 関数名 "claude" を返すため、対話シェル経由でパス解決する外部ツール
# （GUI アプリの中には `zsh -ilc 'command -v claude'` の結果を絶対パス扱いする）が壊れる。
# そもそも中で確認プロンプトを読むので、端末が無い呼び出しでは無効で構わない。
if [[ -t 0 && -t 1 ]]; then
  claude() {
    local ans base
    local is_parent=0
    [[ "$PWD" == "$HOME/src" ]] && is_parent=1
    for base in "${CW_EXTRA_BASES[@]}"; do
      [[ "$PWD" == "$base" ]] && is_parent=1
    done
    case "$is_parent" in
      1)
        echo "claude: $PWD は親ディレクトリです。memory/設定が分散するため個別リポでの起動を推奨します（cw <リポ名> が使えます）。" >&2
        printf 'このまま起動しますか？ [y/N] ' >&2
        read -r ans
        case "$ans" in
          y|Y|yes|YES) ;;
          *) echo "claude: 中止しました" >&2; return 1 ;;
        esac
        ;;
    esac
    local -a name_args model_args
    name_args=(${(f)"$(_claude_auto_name "$@")"})
    model_args=(${(f)"$(_claude_default_model "$@")"})
    command claude "${model_args[@]}" "${name_args[@]}" "$@"
  }
fi

# 引数の先頭が claude のサブコマンド（セッションを開かないもの）なら 0
_claude_is_subcommand() {
  case "$1" in
    agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade) return 0 ;;
  esac
  return 1
}

# 起動のたびに `--model default`（アカウントの既定モデル）を付ける。
# /model で選んだモデルは settings.json の model に保存され、次の起動にも持ち越される。
# 付けないと、一度 fable に切り替えたあとの起動・再開がずっと fable のままになる。
# モデルを別の手段で決めたとき（--model・--agent・ANTHROPIC_MODEL）・サブコマンド・
# ヘルプ・バージョン表示のときは何も出さない（--model は他の指定より優先されるため）。
_claude_default_model() {
  local arg
  [[ -n "${ANTHROPIC_MODEL}" ]] && return 0
  _claude_is_subcommand "$1" && return 0
  for arg in "$@"; do
    case "$arg" in
      --model|--model=*|--agent|--agent=*|-h|--help|-v|--version) return 0 ;;
    esac
  done
  print -rl -- --model default
}

# 新規の対話セッションに `-n <リポ名>-<連番>` を付ける。
# 名前はタブ名（herdr の agents 欄）と、他セッションから見える呼び出し名（ListAgents）の両方に出る。
# 付けないと呼び出し名は `myrepo-fa` のような自動名になり、画面のどこにも出ないので見分けられない。
# 名前の指定・再開・非対話（-p）・サブコマンドのときは何も出さない。
# 連番は実行中の claude プロセスが使っている `-n <リポ名>-N` を避けた最小の番号。
_claude_auto_name() {
  local arg prefix n procs
  _claude_is_subcommand "$1" && return 0
  for arg in "$@"; do
    case "$arg" in
      -n|--name|--name=*|-r|--resume|--resume=*|-c|--continue|--from-pr|--from-pr=*|--session-id|--session-id=*|-p|--print|-h|--help|-v|--version) return 0 ;;
    esac
  done
  prefix="$(git rev-parse --show-toplevel 2>/dev/null)"
  prefix="${${prefix:-$PWD}:t}"
  # 先に一覧を取ってから照合する（パイプで grep すると grep 自身の引数が一覧に載って一致し続ける）
  procs="$(ps -axo command=)"
  procs="${procs//$'\n'/ }"
  n=1
  while [[ " ${procs} " == *" -n ${(b)prefix}-${n} "* ]]; do
    (( n++ ))
  done
  print -rl -- -n "${prefix}-${n}"
}

# chandoff: いま居る Claude Code セッションを Markdown に書き出して次セッションへ引き継ぐ。
# セッション内で `!chandoff` として実行すると CLAUDE_CODE_SESSION_ID が渡り、
# 同一リポで複数タブが走っていても「今いるセッション」を確実に書き出す。
# 新セッション側は /import-claude-session で読み込む（保存先 ~/claude-sessions/）。
chandoff() {
  python3 "$HOME/src/dotfiles/claude/scripts/export-current-session.py" "$@"
}

# サプライチェーン攻撃対策: pip を Flatt 管理レジストリ経由に
export PIP_INDEX_URL=https://pypi.flatt.tech/simple/
# PATH への ~/.local/bin 追加は .zshenv へ移動（非対話シェルからも見えるようにするため）

# Vite+ bin (https://viteplus.dev)
. "$HOME/.vite-plus/env"
