#!/usr/bin/env bash
# Claude Code PreToolUse hook (Edit|Write|MultiEdit)
# テストファイルへのスキップ・無効化パターンの書き込みをブロックする
# （CLAUDE.md「テストを無効化・スキップしない」の機械化）
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

# fail-open（入力異常で exit 0）する経路の痕跡を残す。ログ失敗で hook 自体は壊さない。
# テスト用に HOOKS_ERROR_LOG で差し替え可。
HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"
log_fail() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') guard-test-skip.sh: $1" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
}

# jq が入力パースに失敗したときの診断文字列。生データ（ファイル内容＝機密の恐れ）は残さず、
# 入力バイト数と jq のパースエラー位置（何バイト目で切れたか）だけを残して真因を次回捕捉する。
diag_input() {
    _bytes="$(printf '%s' "$1" | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    _jqerr="$(printf '%s' "$1" | /usr/bin/jq -r '.' 2>&1 1>/dev/null | /usr/bin/tr '\t\n' '  ' | /usr/bin/cut -c1-160)"
    printf 'bytes=%s jqerr=[%s]' "${_bytes}" "${_jqerr}"
}

# ブロック（exit 2）発火を1行TSVで記録する。誤爆・死物を後から追うためのテレメトリ。
# ベストエフォート: 記録に失敗してもブロック自体は壊さない。テスト用に GUARD_HITS_LOG で差し替え可
GUARD_HITS_LOG="${GUARD_HITS_LOG:-${HOME}/.claude/guard-hits.log}"
log_block() {
    detail="$(printf '%s' "$2" | /usr/bin/tr '\t\n' '  ' | /usr/bin/cut -c1-200)"
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" 'guard-test-skip' "$1" "${detail}" \
        >> "${GUARD_HITS_LOG}" 2>/dev/null || true
}

input="$(cat)"

file_path="$(printf '%s' "${input}" | /usr/bin/jq -r '.tool_input.file_path // empty' 2>/dev/null)"
jq_status=$?
if [ "${jq_status}" -ne 0 ]; then
    log_fail "jq parse failed for file_path (exit ${jq_status}) $(diag_input "${input}")"
    exit 0
fi
# file_path キー不在は対象外ツールのペイロード等の正常 skip（ログしない）
[ -z "${file_path}" ] && exit 0

# テストファイル以外は対象外（"skip" という名の正当な実装コード等への誤爆を避ける）
if ! printf '%s\n' "${file_path}" | /usr/bin/grep -qE '_test\.go$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)(__tests__|tests?|spec)/'; then
    exit 0
fi

content="$(printf '%s' "${input}" | /usr/bin/jq -r '
    if .tool_input.new_string then .tool_input.new_string
    elif .tool_input.content then .tool_input.content
    elif .tool_input.edits then ([.tool_input.edits[].new_string] | join("\n"))
    else empty end' 2>/dev/null)"
jq_status=$?
if [ "${jq_status}" -ne 0 ]; then
    log_fail "jq parse failed for content (exit ${jq_status}) $(diag_input "${input}")"
    exit 0
fi
[ -z "${content}" ] && exit 0

# Go: t.Skip/Skipf/SkipNow, JS/TS: .skip( xit( xdescribe( xtest(, Python: skip デコレータ
if printf '%s\n' "${content}" | /usr/bin/grep -qE '\.[Ss]kip(f|Now)?\(|(^|[^A-Za-z0-9_])x(it|describe|test)\(|@unittest\.skip|@pytest\.mark\.skip'; then
    log_block "test-skip-blocked" "${file_path}"
    echo "テストを無効化・スキップしない（CLAUDE.md）。skip パターンを書き込もうとしています: ${file_path} — テスト自体を直すか、どうしても必要ならユーザーに確認してください。" >&2
    exit 2
fi

exit 0
