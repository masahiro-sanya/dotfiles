#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash)
# レビューゲート: リポ root に .claude-review-gate があるリポでは、
# ローカルレビュー通過 HEAD（.git/claude-reviewed-sha、/review-push スキルが記録）と
# 一致しない git push をブロックする。
# 緊急バイパス（ユーザー承認時のみ）: CLAUDE_REVIEW_BYPASS=1 git push
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

# fail-open（入力異常で exit 0）する経路の痕跡を残す。ログ失敗で hook 自体は壊さない
log_fail() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') guard-review-push.sh: $1" >> "${HOME}/.claude/hooks-error.log" 2>/dev/null || true
}

input="$(cat)"
cmd="$(printf '%s' "${input}" | /usr/bin/jq -r '.tool_input.command // empty' 2>/dev/null)"
jq_status=$?
if [ "${jq_status}" -ne 0 ]; then
    log_fail "jq parse failed (exit ${jq_status})"
    exit 0
fi
# command キー不在は Bash 以外のペイロード等の正常 skip（ログしない）
[ -z "${cmd}" ] && exit 0

# コマンド位置の git push（git -C <path> push 形式も対象）だけ検査する
cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*'
if ! printf '%s\n' "${cmd}" | /usr/bin/grep -qE "${cmd_pos}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)"; then
    exit 0
fi

# バイパスは「git push の直前に環境変数代入として置かれた場合」だけ有効。
# 文字列のどこかに含まれるだけでは無効（echo やコミットメッセージ経由の素通りを防ぐ）
if printf '%s\n' "${cmd}" | /usr/bin/grep -qE '(^|[|;&(][[:space:]]*|\$\([[:space:]]*)CLAUDE_REVIEW_BYPASS=1[[:space:]]+git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)'; then
    echo "警告: レビューゲートを CLAUDE_REVIEW_BYPASS=1 でバイパスします。ユーザーの明示承認がない場合は使わないこと。" >&2
    exit 0
fi

# 対象リポの判定優先順位: git -C <path> push > 直前の cd <path> > カレントディレクトリ
dir="$(printf '%s\n' "${cmd}" | /usr/bin/sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]+push.*/\1/p' | head -1)"
if [ -z "${dir}" ]; then
    # `cd <path> && git push` 形式: push より前の最後の cd 先をゲート判定に使う
    before_push="$(printf '%s\n' "${cmd}" | /usr/bin/sed -E 's/git[[:space:]]+push.*$//')"
    dir="$(printf '%s\n' "${before_push}" | /usr/bin/sed -nE "s/(^|.*[|;&(])[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^|;&[:space:]]+)).*/\3\4\5/p" | head -1)"
fi
[ -z "${dir}" ] && dir="${PWD}"
case "${dir}" in "~"*) dir="${HOME}${dir#\~}" ;; esac

repo_root="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "${repo_root}/.claude-review-gate" ] || exit 0

git_dir="$(git -C "${dir}" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
head_sha="$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" || exit 0
reviewed_sha="$(cat "${git_dir}/claude-reviewed-sha" 2>/dev/null || true)"

[ "${reviewed_sha}" = "${head_sha}" ] && exit 0

echo "レビューゲート: このリポは push 前にローカルレビュー必須です（.claude-review-gate あり）。/review-push スキルでレビューを通過させてから push してください。レビュー後に新しいコミットを積んだ場合も再実行が必要です。（通過記録: ${reviewed_sha:-なし} / HEAD: ${head_sha}）" >&2
exit 2
