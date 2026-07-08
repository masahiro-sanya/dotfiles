#!/usr/bin/env bash
# Claude Code hooks -> WezTerm タブに稼働状態を出す。
#
# hook_event_name を見て、ペイン単位の「表示状態ファイル」を書くだけ:
#   <state_dir>/pane-<WEZTERM_PANE>   （中身: busy | waiting | idle | sub:N のいずれか）
# wezterm.lua の format-tab-title が tab.active_pane.pane_id で同じファイルを読む。
# join キーは pane_id（環境変数 WEZTERM_PANE が WezTerm の pane_id と一致する）。
#
# 表示状態は「メイン turn 状態」と「稼働中サブエージェント」から導出する:
#   - main-<pane>             メイン turn の状態: busy(実行中) | idle(待機中) | waiting(要対応)
#   - agent-<pane>-<agent_id> 稼働中サブエージェント 1 体ごとの marker（存在＝稼働中）
#   表示 = 要対応 > サブ稼働(数) > 実行中/待機中。すなわち
#     main==waiting なら waiting、else 稼働サブ数 n>0 なら sub:n、else main。
#
# なぜ「メイン状態」と「サブ marker」を分けるか（実測で確定した理由）:
#  - サブエージェントをバックグラウンド起動すると親 turn はすぐ終わり、Stop hook が
#    "サブ稼働中に" 発火する（このとき agent_id は空）。旧実装のように Stop でカウンタを
#    0 に潰すと、背景 agent が走っているのに待機中/実行中に化ける。Stop は main を idle に
#    するだけで marker は消さない。全 SubagentStop が揃って初めて sub 表示が解ける。
#  - SubagentStop は 1 体につき 2 回発火することがある（非決定的）。数を増減するのでなく
#    agent_id ごとの marker 集合にすることで二重発火に idempotent（重複する touch/rm は no-op）。
#
# なぜ OSC(SetUserVar) でなくファイルか:
#  - Claude Code が hook を起動する子プロセスは制御端末を持たない。/dev/tty は
#    "Device not configured" になり、OSC を tty に出しても WezTerm に届かない。
#  - stdout も使えない（UserPromptSubmit の stdout はプロンプトのコンテキストに注入される）。
#  - ファイルなら tty/stdout 非依存で全イベント一様に確実。
#
# 設計方針（このリポの hooks 共通ルール）:
#  - fail-open: 何があっても exit 0。Claude をブロックしない。異常は hooks-error.log に痕跡。
#  - macOS 標準 bash 3.2 互換。変数展開は ${var} 形式。
#  - 非 WezTerm(WEZTERM_PANE 未設定)では完全に no-op（他端末で誤動作しない）。
#  - stdout には一切書かない。
#
# テスト用フック(env で差し替え):
#  - WEZTERM_STATE_DIR : 状態ファイル群の保存先（既定 ~/.claude/wezterm-state）
set -u

log_err() {
  printf '%s wezterm-status: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" "$1" \
    >> "${HOME}/.claude/hooks-error.log" 2>/dev/null
}

# 非 WezTerm では無効（fail-safe）
[ -z "${WEZTERM_PANE:-}" ] && exit 0

# hook JSON を stdin から読む（端末直叩き等で stdin が tty のときは読まない）
input=""
if [ ! -t 0 ]; then
  input="$(cat 2>/dev/null)"
fi

# イベント名と agent_id を取り出す（jq 失敗時は空のまま続行 = fail-open）
event=""
aid=""
if [ -n "${input}" ] && command -v jq >/dev/null 2>&1; then
  IFS=$'\t' read -r event aid <<EOF
$(printf '%s' "${input}" | jq -r '[(.hook_event_name // ""), (.agent_id // "")] | @tsv' 2>/dev/null)
EOF
fi
# 保険: 登録側から第1引数でイベント名を渡された場合はそちらを優先
[ -n "${1:-}" ] && event="$1"

state_dir="${WEZTERM_STATE_DIR:-${HOME}/.claude/wezterm-state}"
mkdir -p "${state_dir}" 2>/dev/null

pane_safe="$(printf '%s' "${WEZTERM_PANE}" | tr -c 'A-Za-z0-9._-' '_')"
aid_safe="$(printf '%s' "${aid}" | tr -c 'A-Za-z0-9._-' '_')"
state_file="${state_dir%/}/pane-${pane_safe}"          # wezterm が読む「表示状態」
main_file="${state_dir%/}/main-${pane_safe}"           # メイン turn 状態: busy|idle|waiting
agent_prefix="${state_dir%/}/agent-${pane_safe}-"      # 稼働中サブの marker 群
lock_dir="${state_dir%/}/pane-${pane_safe}.lock"

read_main() {
  _m="$(cat "${main_file}" 2>/dev/null)"
  case "${_m}" in
    busy|idle|waiting) printf '%s' "${_m}" ;;
    *) printf 'idle' ;;                                 # 未設定/破損時は idle 既定
  esac
}
write_main() { printf '%s' "$1" > "${main_file}" 2>/dev/null; }

# 稼働中サブ数 = agent-<pane>-* marker の個数。マッチ無しはグロブがリテラルで残るので -e で弾く。
count_agents() {
  _n=0
  for _m in "${agent_prefix}"*; do
    [ -e "${_m}" ] && _n=$((_n + 1))
  done
  printf '%s' "${_n}"
}
clear_agents() { command rm -f "${agent_prefix}"* 2>/dev/null; }

# 表示ファイルの read-modify-write を直列化（並列サブの起動/終了に備える。
# 取れなくても続行＝多少のズレは次イベントで自己回復するので実害小）。
_locked=""
_i=0
while [ "${_i}" -lt 20 ]; do
  if mkdir "${lock_dir}" 2>/dev/null; then _locked=1; break; fi
  _i=$((_i + 1))
  sleep 0.05 2>/dev/null || _i=20
done

clear=""
case "${event}" in
  UserPromptSubmit)
    write_main "busy" ;;
  Notification)
    write_main "waiting" ;;
  Stop|StopFailure)
    write_main "idle" ;;                                # marker は消さない（背景 agent を生かす）
  SessionStart)
    write_main "idle"; clear_agents ;;                  # 新セッションでサブ marker を掃除（leak 回復）
  SubagentStart)
    [ -n "${aid_safe}" ] && : > "${agent_prefix}${aid_safe}" 2>/dev/null ;;
  SubagentStop)
    [ -n "${aid_safe}" ] && command rm -f "${agent_prefix}${aid_safe}" 2>/dev/null ;;
  SessionEnd)
    clear=1 ;;
  *)
    [ -n "${_locked}" ] && rmdir "${lock_dir}" 2>/dev/null
    exit 0 ;;
esac

# 表示状態を (メイン状態, 稼働サブ数) から導出して書く。
# SessionEnd はファイル群を消してタブをリポ名だけに戻す。
if [ -n "${clear}" ]; then
  command rm -f "${state_file}" "${main_file}" 2>/dev/null
  clear_agents
else
  main="$(read_main)"
  n="$(count_agents)"
  if [ "${main}" = "waiting" ]; then
    display="waiting"                                   # 要対応は最優先（サブ稼働より前）
  elif [ "${n}" -gt 0 ]; then
    display="sub:${n}"
  else
    display="${main}"
  fi
  # temp+mv で原子的に差し替え（wezterm 側が書き込み途中を読まないように）
  tmp="${state_file}.$$"
  if printf '%s' "${display}" > "${tmp}" 2>/dev/null; then
    mv -f "${tmp}" "${state_file}" 2>/dev/null || {
      command rm -f "${tmp}" 2>/dev/null
      log_err "mv failed: event=${event} file=${state_file}"
    }
  else
    log_err "write failed: event=${event} file=${state_file}"
  fi
fi

[ -n "${_locked}" ] && rmdir "${lock_dir}" 2>/dev/null
exit 0
