#!/usr/bin/env bash
# Claude Code Stop hook — このセッションの chrome-devtools MCP が開いた Chrome を閉じる
#
# chrome-devtools-mcp は Chrome を自分の子として起動し、閉じるのは MCP のセッションが
# 終わるとき（stdin EOF / SIGTERM）だけ。ターンが終わっても Chrome が開きっぱなしになる。
# 最後のタブは close_page で閉じられないので、ルールで「閉じて」と書いても閉じきれない。
# MCP は次のブラウザ操作で browser.connected を見て起動し直すので、ここで閉じても壊れない
# （代償: 次に使うときは起動し直しになる。「ブラウザで見て」と返したターンでも閉じる）。
#
# 閉じる対象（全部満たすものだけ）:
#  - 起動行に chrome-devtools-mcp/chrome-profile を含む（MCP の既定プロファイル）
#  - 親が chrome-devtools-mcp のプロセス（= MCP が起動した Chrome 本体。Helper は本体と一緒に終わる）
#    文字列だけで選ぶと、起動行にこの文字列を含むシェル（pgrep -f 等）まで閉じる。
#    実機で Bash ツールのシェル自身を閉じた実例があるので、親で絞る
#  - 祖先に、この hook を起動した claude プロセスが居る（別セッションの Chrome に触らない）
# 普段使いの Chrome は chrome-profile を含まないので対象外。
#
# fail-open: ps が取れない・claude の祖先が見つからないときは何もせず exit 0、
# ~/.claude/hooks-error.log に痕跡を残す。stdout には何も出さない。
#
# テスト用フック(env で差し替え):
#  - CLOSE_MCP_BROWSER_PS_FILE  : `ps -axo pid=,ppid=,command=` の代わりに読むファイル
#  - CLOSE_MCP_BROWSER_SELF_PID : 祖先をたどる起点の PID（既定はこの hook 自身の $$）
#  - CLOSE_MCP_BROWSER_KILL     : kill の代わりに呼ぶコマンド
#  - HOOKS_ERROR_LOG            : 痕跡ログの書き先

set -u

HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"
log_error() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') close-mcp-browser.sh: $1" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
}

# stdin（Stop の JSON）は使わないが、書き手を詰まらせないよう読み捨てる
cat >/dev/null 2>&1 || true

SELF_PID="${CLOSE_MCP_BROWSER_SELF_PID:-$$}"
KILL_CMD="${CLOSE_MCP_BROWSER_KILL:-kill}"

if [ -n "${CLOSE_MCP_BROWSER_PS_FILE:-}" ]; then
  SNAPSHOT="$(cat "${CLOSE_MCP_BROWSER_PS_FILE}" 2>/dev/null)"
else
  SNAPSHOT="$(ps -axo pid=,ppid=,command= 2>/dev/null)"
fi
if [ -z "${SNAPSHOT}" ]; then
  log_error "ps の出力が空（何もしない）"
  exit 0
fi

# 1 行目に claude の PID（見つからなければ none）、2 行目以降に閉じる PID を出す
RESULT="$(printf '%s\n' "${SNAPSHOT}" | awk -v self="${SELF_PID}" '
  {
    pid = $1; ppid = $2
    cmd = $0
    sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
    first = cmd; sub(/[ \t].*$/, "", first); sub(/^.*\//, "", first)
    parent[pid] = ppid; command[pid] = cmd; name[pid] = first
  }
  # 2 つ目は process.title が付かない起動（node …/chrome-devtools-mcp/…）向け。
  # 実行ファイルを node に限るのは、起動行にこの文字列を含むシェルを MCP と取り違えないため
  function is_mcp(p) { return name[p] == "chrome-devtools-mcp" || (name[p] == "node" && index(command[p], "node_modules/chrome-devtools-mcp/") > 0) }
  function is_mcp_chrome(p) { return is_mcp(parent[p]) && index(command[p], "chrome-devtools-mcp/chrome-profile") > 0 }
  END {
    claude = ""
    p = self
    for (i = 0; i < 64 && (p in parent); i++) {
      if (name[p] == "claude") { claude = p; break }
      p = parent[p]
    }
    if (claude == "") { print "none"; exit }
    print claude
    # Chrome から上へたどって最初に当たった claude が自分のときだけ対象にする。
    # 自分のセッションの Bash ツールから起動した入れ子の claude（claude -p 等）の Chrome も
    # 自分の子孫になるため、「祖先のどこかに自分が居る」だけでは別セッションを巻き込む。
    for (pid in command) {
      if (!is_mcp_chrome(pid)) continue
      p = parent[pid]
      for (i = 0; i < 64 && (p in parent); i++) {
        if (name[p] == "claude") { if (p == claude) print pid " " parent[pid]; break }
        p = parent[p]
      }
    }
  }
')"

CLAUDE_PID="$(printf '%s\n' "${RESULT}" | sed -n 1p)"
if [ "${CLAUDE_PID}" = "none" ] || [ -z "${CLAUDE_PID}" ]; then
  log_error "祖先に claude が見つからない（起点 PID ${SELF_PID}。何もしない）"
  exit 0
fi

printf '%s\n' "${RESULT}" | sed -n '2,$p' | while read -r target target_ppid; do
  [ -n "${target}" ] || continue
  # スナップショットから kill までの間に Chrome が終わって PID が再利用されていないか、
  # 送る直前に親と起動行を取り直して確かめる（フィクスチャ実行時は取り直す先が無いので省く）
  if [ -z "${CLOSE_MCP_BROWSER_PS_FILE:-}" ]; then
    CURRENT="$(ps -o ppid= -o command= -p "${target}" 2>/dev/null)"
    CURRENT_PPID="$(printf '%s\n' "${CURRENT}" | awk 'NR==1{print $1}')"
    case "${CURRENT}" in
      *chrome-devtools-mcp/chrome-profile*) ;;
      *) continue ;;
    esac
    [ "${CURRENT_PPID}" = "${target_ppid}" ] || continue
  fi
  "${KILL_CMD}" -TERM "${target}" >/dev/null 2>&1 || log_error "kill -TERM ${target} に失敗"
done

exit 0
