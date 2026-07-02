#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash)
# CLAUDE.md の散文ルールの機械化:
#   - grep/find をコマンド位置で検知してブロックし rg/fd へ誘導
#   - git の --no-verify をブロック（「テストを無効化・スキップしない」）
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

input="$(cat)"
cmd="$(printf '%s' "$input" | /usr/bin/jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# コマンド位置（行頭・パイプ・; & の直後・$( や ` の直後）のみ検知する。
# 境界: `git grep` や引数・文字列中の grep/find は許容（コマンド位置に来ないため）。
# 検知漏れ許容: xargs/env/time 経由の間接実行までは追わない。
cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*(command[[:space:]]+)?(sudo[[:space:]]+)?'

if printf '%s\n' "$cmd" | /usr/bin/grep -qE "${cmd_pos}(grep|egrep|fgrep)([[:space:]]|$)"; then
    echo "grep は使わない（CLAUDE.md）。rg（ripgrep）で書き直してください。例: rg -n 'pattern' path/" >&2
    exit 2
fi

if printf '%s\n' "$cmd" | /usr/bin/grep -qE "${cmd_pos}find([[:space:]]|$)"; then
    echo "find は使わない（CLAUDE.md）。fd で書き直してください。例: fd 'name' path/ / fd -e go" >&2
    exit 2
fi

# --no-verify はクォート内（コミットメッセージ等のデータ）を除去してから判定する
# （メッセージ本文に "--no-verify" と書いただけで誤爆しないように）
cmd_stripped="$(printf '%s' "$cmd" | /usr/bin/perl -0777 -pe "s/\"[^\"]*\"//gs; s/'[^']*'//gs" 2>/dev/null || printf '%s' "$cmd")"

if printf '%s\n' "$cmd_stripped" | /usr/bin/grep -qE "${cmd_pos}git[[:space:]][^|;&]*[[:space:]]--no-verify"; then
    echo "--no-verify は禁止（CLAUDE.md「テストを無効化・スキップしない」）。フックが失敗するなら原因を修正してください。" >&2
    exit 2
fi

exit 0
