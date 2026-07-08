#!/usr/bin/env bash
# Claude Code hooks -> WezTerm タブに稼働状態を出す。
#
# hook_event_name を見て状態を決め、ペイン単位の状態ファイルに書くだけ:
#   <state_dir>/pane-<WEZTERM_PANE>   （中身は busy | waiting | idle | sub:N のいずれか）
# wezterm.lua の format-tab-title が tab.active_pane.pane_id で同じファイルを読む。
# join キーは pane_id（環境変数 WEZTERM_PANE が WezTerm の pane_id と一致する）。
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
#  - WEZTERM_STATE_DIR : 状態ファイル/サブエージェント数カウンタの保存先（既定 ~/.claude/wezterm-state）
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

# イベント名と session_id を取り出す（jq 失敗時は空のまま続行 = fail-open）
event=""
sid=""
if [ -n "${input}" ] && command -v jq >/dev/null 2>&1; then
  IFS=$'\t' read -r event sid <<EOF
$(printf '%s' "${input}" | jq -r '[(.hook_event_name // ""), (.session_id // "")] | @tsv' 2>/dev/null)
EOF
fi
# 保険: 登録側から第1引数でイベント名を渡された場合はそちらを優先
[ -n "${1:-}" ] && event="$1"

state_dir="${WEZTERM_STATE_DIR:-${HOME}/.claude/wezterm-state}"
mkdir -p "${state_dir}" 2>/dev/null

# 状態ファイル(ペイン単位) と サブエージェント数カウンタ(session 単位)
pane_safe="$(printf '%s' "${WEZTERM_PANE}" | tr -c 'A-Za-z0-9._-' '_')"
state_file="${state_dir%/}/pane-${pane_safe}"
sid_safe="$(printf '%s' "${sid:-nosession}" | tr -c 'A-Za-z0-9._-' '_')"
cnt_file="${state_dir%/}/sub-${sid_safe}"
lock_dir="${cnt_file}.lock"

read_cnt() {
  _c="$(cat "${cnt_file}" 2>/dev/null)"
  case "${_c}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "${_c}" ;;
  esac
}
write_cnt() { printf '%s' "$1" > "${cnt_file}" 2>/dev/null; }

# カウンタ更新の直列化（並列 Subagent 起動に備える。取れなくても続行=多少のズレは実害小）
_locked=""
_i=0
while [ "${_i}" -lt 20 ]; do
  if mkdir "${lock_dir}" 2>/dev/null; then _locked=1; break; fi
  _i=$((_i + 1))
  sleep 0.05 2>/dev/null || _i=20
done

state=""
clear=""
case "${event}" in
  UserPromptSubmit)
    state="busy" ;;
  SubagentStart)
    n=$(read_cnt); n=$((n + 1)); write_cnt "${n}"; state="sub:${n}" ;;
  SubagentStop)
    n=$(read_cnt); n=$((n - 1)); [ "${n}" -lt 0 ] && n=0; write_cnt "${n}"
    if [ "${n}" -gt 0 ]; then state="sub:${n}"; else state="busy"; fi ;;
  Notification)
    state="waiting" ;;
  Stop|StopFailure)
    write_cnt 0; state="idle" ;;
  SessionStart)
    write_cnt 0; state="idle" ;;
  SessionEnd)
    write_cnt 0; clear=1 ;;
  *)
    [ -n "${_locked}" ] && rmdir "${lock_dir}" 2>/dev/null
    exit 0 ;;
esac

[ -n "${_locked}" ] && rmdir "${lock_dir}" 2>/dev/null

# 状態ファイルを更新。SessionEnd はファイルを消してタブをリポ名だけに戻す。
if [ -n "${clear}" ]; then
  command rm -f "${state_file}" "${cnt_file}" 2>/dev/null
else
  # temp+mv で原子的に差し替え（wezterm 側が書き込み途中を読まないように）
  tmp="${state_file}.$$"
  if printf '%s' "${state}" > "${tmp}" 2>/dev/null; then
    mv -f "${tmp}" "${state_file}" 2>/dev/null || {
      command rm -f "${tmp}" 2>/dev/null
      log_err "mv failed: event=${event} file=${state_file}"
    }
  else
    log_err "write failed: event=${event} file=${state_file}"
  fi
fi

exit 0
