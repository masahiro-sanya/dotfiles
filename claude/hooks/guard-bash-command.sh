#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash)
# CLAUDE.md の散文ルールの機械化:
#   - grep/find をコマンド位置で検知してブロックし rg/fd へ誘導
#   - git の --no-verify をブロック（「テストを無効化・スキップしない」）
#   - main/master への直接 git commit をブロック（「feature branchで作業」）
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

# fail-open（入力異常で exit 0）する経路の痕跡を残す。ログ失敗で hook 自体は壊さない。
# テスト用に HOOKS_ERROR_LOG で差し替え可。
HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"
log_fail() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') guard-bash-command.sh: $1" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
}

# jq が入力パースに失敗したときの診断文字列。生データ（コマンド全文＝機密の恐れ）は残さず、
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
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" 'guard-bash-command' "$1" "${detail}" \
        >> "${GUARD_HITS_LOG}" 2>/dev/null || true
}

input="$(cat)"
cmd="$(printf '%s' "${input}" | /usr/bin/jq -r '.tool_input.command // empty' 2>/dev/null)"
jq_status=$?
if [ "${jq_status}" -ne 0 ]; then
    log_fail "jq parse failed (exit ${jq_status}) $(diag_input "${input}")"
    exit 0
fi
# command キー不在は Bash 以外のペイロード等の正常 skip（ログしない）
[ -z "${cmd}" ] && exit 0

# コマンド位置（行頭・パイプ・; & の直後・$( や ` の直後）のみ検知する。
# 境界: `git grep` や引数・文字列中の grep/find は許容（コマンド位置に来ないため）。
# 検知漏れ許容: xargs/env/time 経由の間接実行までは追わない。
cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*(command[[:space:]]+)?(sudo[[:space:]]+)?'

if printf '%s\n' "${cmd}" | /usr/bin/grep -qE "${cmd_pos}(grep|egrep|fgrep)([[:space:]]|$)"; then
    log_block "grep-blocked" "${cmd}"
    echo "grep は使わない（CLAUDE.md）。rg（ripgrep）で書き直してください。例: rg -n 'pattern' path/" >&2
    exit 2
fi

if printf '%s\n' "${cmd}" | /usr/bin/grep -qE "${cmd_pos}find([[:space:]]|$)"; then
    log_block "find-blocked" "${cmd}"
    echo "find は使わない（CLAUDE.md）。fd で書き直してください。例: fd 'name' path/ / fd -e go" >&2
    exit 2
fi

# 素の rm をブロック（CLAUDE.md「この環境の rm は -i エイリアス。非対話実行では
# 削除されないまま exit 0 になる → command rm -f を使い ls で裏取り」の機械化）。
# 正規の回避形である `command rm` / `sudo rm`（どちらもエイリアスを迂回する）は許可したいので、
# cmd_pos の command/sudo プレフィックス付きアンカーは使わず、区切り直後の rm だけを検知する。
# `command rm` は rm が区切り直後に来ない（command の後）ため、この pattern には一致しない。
rm_pos='(^|[|;&(]|\$\(|`)[[:space:]]*'
if printf '%s\n' "${cmd}" | /usr/bin/grep -qE "${rm_pos}rm([[:space:]]|$)"; then
    log_block "bare-rm-blocked" "${cmd}"
    echo "素の rm は使わない（CLAUDE.md）。この環境の rm は -i エイリアスで、非対話実行だと削除されないまま exit 0 になる。command rm -f で実行し、削除後に ls で裏取りしてください。" >&2
    exit 2
fi

# --no-verify / git commit 検知はクォート内（コミットメッセージ等のデータ）を
# 除去してから判定する（メッセージ本文に書いただけで誤爆しないように）
cmd_stripped="$(printf '%s' "${cmd}" | /usr/bin/perl -0777 -pe "s/\"[^\"]*\"//gs; s/'[^']*'//gs" 2>/dev/null || printf '%s' "${cmd}")"

if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}git[[:space:]][^|;&]*[[:space:]]--no-verify"; then
    log_block "no-verify-blocked" "${cmd_stripped}"
    echo "--no-verify は禁止（CLAUDE.md「テストを無効化・スキップしない」）。フックが失敗するなら原因を修正してください。" >&2
    exit 2
fi

# main/master への直接 commit をブロック（「feature branchで作業、mainには直接コミットしない」）
# 例外: リポ root に .claude-allow-main マーカーがあるリポ（main 直運用のメモ系リポ等）は許可。
# detached HEAD（branch --show-current が空）はリベース等の正当な操作なので許可。
if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$)"; then
    commit_dir="$(printf '%s\n' "${cmd_stripped}" | /usr/bin/sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]+commit.*/\1/p' | head -1)"
    [ -z "${commit_dir}" ] && commit_dir="${PWD}"
    case "${commit_dir}" in "~"*) commit_dir="${HOME}${commit_dir#\~}" ;; esac
    branch="$(git -C "${commit_dir}" branch --show-current 2>/dev/null || true)"
    if [ "${branch}" = "main" ] || [ "${branch}" = "master" ]; then
        repo_root="$(git -C "${commit_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "${repo_root}" ] && [ ! -f "${repo_root}/.claude-allow-main" ]; then
            log_block "main-commit-blocked" "branch=${branch} ${cmd_stripped}"
            echo "main には直接コミットしない（CLAUDE.md）。feature branch を切ってから commit してください（例: git checkout -b feat/xxx）。このリポで main 直コミットを許可する場合はユーザー承認の上 repo root に .claude-allow-main を置く。" >&2
            exit 2
        fi
    fi
fi

exit 0
