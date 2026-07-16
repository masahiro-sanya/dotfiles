#!/bin/bash
# mark-external-fetch.sh — PostToolUse hook (WebFetch|WebSearch)
# 外部コンテンツを取得した時刻を session 単位の marker に記録する。
# bash-guard.sh の Phase 0.5（外部接触ガード）が「WebFetch/WebSearch 直後ウィンドウ」
# の判定にこの marker を使う。プロンプトインジェクション混入直後の外部送信を ask に
# 引き上げるための痕跡。marker は時刻ベースで自然失効するため掃除は不要。
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
# session_id は marker のファイルパスに使うため英数・ハイフン・アンダースコア以外を除去
SID=$(printf '%s' "${SID:-}" | tr -cd 'a-zA-Z0-9_-')
[ -z "${SID:-}" ] && SID="default"

MARKER="${TMPDIR:-/tmp}/claude-extfetch-${SID}.marker"
date +%s > "$MARKER" 2>/dev/null || true
exit 0
