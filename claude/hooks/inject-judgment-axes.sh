#!/usr/bin/env bash
# UserPromptSubmit hook: ユーザーの判断軸を毎回の依頼の文脈に差し込む。
#
# 差し込む中身はこのリポ（公開）には置かない。マシンのローカルにだけある
#   ~/.claude/private/judgment-axes.md
# を読み、hookSpecificOutput.additionalContext として出すだけ。
# ファイルが無い・読めない・大きすぎる・jq が無い、のどれでも何も出さず exit 0（fail-open。依頼の送信を止めない）。
#
# 該当する依頼かどうかの判定はしない（キーワード判定は取りこぼしが多いため）。毎回差し込み、使うかは Claude が見分ける。
#
# 環境変数（テスト用）:
#   JUDGMENT_AXES_FILE   差し込む元ファイル（既定: ~/.claude/private/judgment-axes.md）
#   JUDGMENT_AXES_MAX    上限バイト数。超えたら出さない（既定: 4096）
#   HOOKS_ERROR_LOG      fail-open の痕跡ログ（既定: ~/.claude/hooks-error.log）

AXES_FILE="${JUDGMENT_AXES_FILE:-${HOME}/.claude/private/judgment-axes.md}"
MAX_BYTES="${JUDGMENT_AXES_MAX:-4096}"
HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"
# 数値でない上限は [ -gt ] がエラーで偽になり、上限なしで出てしまうので既定に戻す
case "${MAX_BYTES}" in
    ''|*[!0-9]*) MAX_BYTES=4096 ;;
esac

log_error() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') inject-judgment-axes.sh: ${1}" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
}

# stdin は使わないが、書き手を詰まらせないよう読み捨てる
cat >/dev/null 2>&1 || true

# ファイルが無いマシン（私用 Mac 等）は正常系なので痕跡を残さない
[ -f "${AXES_FILE}" ] || exit 0

if [ ! -r "${AXES_FILE}" ]; then
    log_error "読めない: ${AXES_FILE}"
    exit 0
fi

size="$(wc -c < "${AXES_FILE}" 2>/dev/null | tr -d ' ')"
case "${size}" in
    ''|*[!0-9]*) log_error "サイズが取れない: ${AXES_FILE}"; exit 0 ;;
esac
[ "${size}" -gt 0 ] || exit 0
if [ "${size}" -gt "${MAX_BYTES}" ]; then
    log_error "上限 ${MAX_BYTES} バイトを超えたので出さない（${size} バイト）: ${AXES_FILE}"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    log_error "jq が無い"
    exit 0
fi

out="$(jq -n --rawfile ctx "${AXES_FILE}" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null)"
if [ -z "${out}" ]; then
    log_error "jq で組み立てられない: ${AXES_FILE}"
    exit 0
fi

printf '%s\n' "${out}"
exit 0
