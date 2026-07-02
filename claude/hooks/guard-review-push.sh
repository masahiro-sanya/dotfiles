#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash)
# レビューゲート: リポ root に .claude-review-gate があるリポでは、
# ローカルレビュー通過 HEAD（.git/claude-reviewed-sha、/review-push スキルが記録）と
# 一致しない git push をブロックする。
# 緊急バイパス（ユーザー承認時のみ）: CLAUDE_REVIEW_BYPASS=1 git push
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

input="$(cat)"
cmd="$(printf '%s' "$input" | /usr/bin/jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# コマンド位置の git push（git -C <path> push 形式も対象）だけ検査する
cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*'
if ! printf '%s\n' "$cmd" | /usr/bin/grep -qE "${cmd_pos}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)"; then
    exit 0
fi

printf '%s\n' "$cmd" | /usr/bin/grep -q 'CLAUDE_REVIEW_BYPASS=1' && exit 0

# 対象リポ: git -C <path> push なら <path>、それ以外はカレントディレクトリ
dir="$(printf '%s\n' "$cmd" | /usr/bin/sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]+push.*/\1/p' | head -1)"
[ -z "$dir" ] && dir="$PWD"

repo_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$repo_root/.claude-review-gate" ] || exit 0

git_dir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
head_sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || exit 0
reviewed_sha="$(cat "$git_dir/claude-reviewed-sha" 2>/dev/null || true)"

[ "$reviewed_sha" = "$head_sha" ] && exit 0

echo "レビューゲート: このリポは push 前にローカルレビュー必須です（.claude-review-gate あり）。/review-push スキルでレビューを通過させてから push してください。レビュー後に新しいコミットを積んだ場合も再実行が必要です。（通過記録: ${reviewed_sha:-なし} / HEAD: ${head_sha}）" >&2
exit 2
