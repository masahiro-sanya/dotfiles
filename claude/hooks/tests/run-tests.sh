#!/usr/bin/env bash
# claude/hooks の回帰テスト（bats 不要・macOS bash 3.2 互換）
# 使い方: bash claude/hooks/tests/run-tests.sh
# 各ケース: PreToolUse 相当の JSON を stdin から hook に流し、exit code を検証する
#
# 注意: skip パターンのフィクスチャは "t.Sk""ip(" のようにシェル連結で分割してある。
# このファイル自体が guard-test-skip.sh の検知対象パス（tests/）にあるため、
# リテラルで書くと編集がガードにブロックされる（実行時には連結されて完全な文字列になる）。

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'command rm -rf "${TMP_ROOT}"' EXIT

# ブロック発火テレメトリのログを本物（~/.claude/guard-hits.log）でなくテスト用に向ける
export GUARD_HITS_LOG="${TMP_ROOT}/guard-hits.log"

PASS=0
FAIL=0

# assert <期待exit> <hookファイル名> <説明> <JSON> [実行ディレクトリ]
# hook は $PWD を見るものがあるため、5番目の引数でカレントディレクトリを指定できる
assert() {
    expected="$1"
    hook="$2"
    desc="$3"
    json="$4"
    run_dir="${5:-${TMP_ROOT}}"
    ( cd "${run_dir}" && printf '%s' "${json}" | bash "${HOOKS_DIR}/${hook}" >/dev/null 2>&1 )
    actual=$?
    if [ "${actual}" -eq "${expected}" ]; then
        PASS=$((PASS + 1))
        echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1))
        echo "  NG: ${desc} (expected exit ${expected}, got ${actual})"
    fi
}

# Bash ツールの PreToolUse ペイロード（jq でエスケープして組み立てる）
bash_json() {
    /usr/bin/jq -cn --arg cmd "$1" '{tool_input: {command: $cmd}}'
}

# Edit ツールの PreToolUse ペイロード
edit_json() {
    /usr/bin/jq -cn --arg fp "$1" --arg ns "$2" '{tool_input: {file_path: $fp, new_string: $ns}}'
}

# テスト用 git リポを作る: make_repo <path> <branch>
make_repo() {
    git init -q "$1"
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
    git -C "$1" -c user.email=test@example.com -c user.name=test \
        commit -q --allow-empty -m init
}

REPO_MAIN="${TMP_ROOT}/repo-main"
REPO_MAIN_ALLOWED="${TMP_ROOT}/repo-main-allowed"
REPO_FEATURE="${TMP_ROOT}/repo-feature"
REPO_GATED="${TMP_ROOT}/repo-gated"
REPO_PLAIN="${TMP_ROOT}/repo-plain"

make_repo "${REPO_MAIN}" main
make_repo "${REPO_MAIN_ALLOWED}" main
touch "${REPO_MAIN_ALLOWED}/.claude-allow-main"
make_repo "${REPO_FEATURE}" feat/test
make_repo "${REPO_GATED}" main
touch "${REPO_GATED}/.claude-review-gate"
make_repo "${REPO_PLAIN}" main

echo "== guard-bash-command.sh =="

assert 2 guard-bash-command.sh "grep はブロック" "$(bash_json "grep foo bar.txt")"
assert 2 guard-bash-command.sh "パイプ先の grep もブロック" "$(bash_json "cat a.txt | grep foo")"
assert 0 guard-bash-command.sh "git grep は許可（コマンド位置でない）" "$(bash_json "git grep foo")"
assert 0 guard-bash-command.sh "引数中の grep は許可" "$(bash_json "rg -n 'use grep here' docs/")"
assert 2 guard-bash-command.sh "find はブロック" "$(bash_json "find . -name '*.go'")"
assert 0 guard-bash-command.sh "fd は許可" "$(bash_json "fd -e go")"
assert 2 guard-bash-command.sh "素の rm はブロック" "$(bash_json "rm foo.txt")"
assert 2 guard-bash-command.sh "&& 後の素の rm もブロック" "$(bash_json "cd /tmp && rm x")"
assert 0 guard-bash-command.sh "command rm は許可（正規の回避形）" "$(bash_json "command rm -f foo")"
assert 0 guard-bash-command.sh "sudo rm は許可（エイリアス迂回）" "$(bash_json "sudo rm -f /var/x")"
assert 0 guard-bash-command.sh "rmdir は誤爆しない" "$(bash_json "rmdir emptydir")"
assert 0 guard-bash-command.sh "引用符内の rm 文字列は許可" "$(bash_json "rg -n 'rm -rf' docs/")"
assert 2 guard-bash-command.sh "--no-verify はブロック" "$(bash_json "git commit --no-verify -m x")" "${REPO_FEATURE}"
assert 0 guard-bash-command.sh "引用符内の --no-verify は許可" "$(bash_json "git commit -m 'do not use --no-verify'")" "${REPO_FEATURE}"
assert 2 guard-bash-command.sh "main での git commit はブロック（PWD 判定）" "$(bash_json "git commit -m x")" "${REPO_MAIN}"
assert 2 guard-bash-command.sh "main での git -C commit はブロック" "$(bash_json "git -C ${REPO_MAIN} commit -m x")"
assert 0 guard-bash-command.sh ".claude-allow-main があれば main commit 許可" "$(bash_json "git -C ${REPO_MAIN_ALLOWED} commit -m x")"
assert 0 guard-bash-command.sh "feature branch の commit は許可" "$(bash_json "git commit -m x")" "${REPO_FEATURE}"
assert 0 guard-bash-command.sh "メッセージ内の 'git commit' では誤爆しない" "$(bash_json "echo 'run: git commit' > note.txt")" "${REPO_MAIN}"
assert 0 guard-bash-command.sh "リポ外の git commit は許可（branch 取得不能）" "$(bash_json "git commit -m x")" "${TMP_ROOT}"
assert 0 guard-bash-command.sh "壊れた JSON は fail-open" "{broken json"

echo "== guard-review-push.sh =="

assert 2 guard-review-push.sh "ゲートリポで未レビュー push はブロック" "$(bash_json "git push")" "${REPO_GATED}"
assert 2 guard-review-push.sh "git -C 形式でもブロック" "$(bash_json "git -C ${REPO_GATED} push")"
assert 2 guard-review-push.sh "cd <gated> && git push もブロック" "$(bash_json "cd ${REPO_GATED} && git push")" "${REPO_PLAIN}"
assert 0 guard-review-push.sh "先頭のバイパスは有効" "$(bash_json "CLAUDE_REVIEW_BYPASS=1 git push")" "${REPO_GATED}"
assert 2 guard-review-push.sh "文字列途中のバイパスは無効" "$(bash_json "echo CLAUDE_REVIEW_BYPASS=1 && git push")" "${REPO_GATED}"
assert 0 guard-review-push.sh "ゲートなしリポの push は許可" "$(bash_json "git push")" "${REPO_PLAIN}"
assert 0 guard-review-push.sh "push 以外の git は対象外" "$(bash_json "git status")" "${REPO_GATED}"
assert 0 guard-review-push.sh "壊れた JSON は fail-open" "{broken json"

# レビュー通過記録が HEAD と一致すれば push できる
gated_git_dir="$(git -C "${REPO_GATED}" rev-parse --absolute-git-dir)"
git -C "${REPO_GATED}" rev-parse HEAD > "${gated_git_dir}/claude-reviewed-sha"
assert 0 guard-review-push.sh "レビュー通過済み HEAD の push は許可" "$(bash_json "git push")" "${REPO_GATED}"

echo "== guard-test-skip.sh =="

assert 2 guard-test-skip.sh "テストファイルへの skip 書き込みはブロック" "$(edit_json "foo_test.go" "t.Sk""ip(\"flaky\")")"
assert 0 guard-test-skip.sh "非テストファイルの skip 文字列は許可" "$(edit_json "main.go" "t.Sk""ip(\"flaky\")")"
assert 0 guard-test-skip.sh "テストファイルへの通常編集は許可" "$(edit_json "foo_test.go" "assert.Equal(t, 1, got)")"
assert 2 guard-test-skip.sh "spec ファイルへの xit はブロック" "$(edit_json "src/foo.spec.ts" "x""it('works', () => {})")"
assert 0 guard-test-skip.sh "壊れた JSON は fail-open" "{broken json"

echo "== guard-hits テレメトリ =="

# ブロック時に GUARD_HITS_LOG へ 1 行記録されることを確認する
# check_logged <説明> <期待reason> <hook> <JSON> [run_dir]
check_logged() {
    desc="$1"; want="$2"; hook="$3"; json="$4"; run_dir="${5:-${TMP_ROOT}}"
    command rm -f "${GUARD_HITS_LOG}"
    ( cd "${run_dir}" && printf '%s' "${json}" | bash "${HOOKS_DIR}/${hook}" >/dev/null 2>&1 )
    if [ -f "${GUARD_HITS_LOG}" ] && /usr/bin/grep -q "${want}" "${GUARD_HITS_LOG}"; then
        PASS=$((PASS + 1)); echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  NG: ${desc}（${want} が記録されていない）"
    fi
}

# 許可（exit 0）のときは記録しないことを確認する
# check_not_logged <説明> <hook> <JSON> [run_dir]
check_not_logged() {
    desc="$1"; hook="$2"; json="$3"; run_dir="${4:-${TMP_ROOT}}"
    command rm -f "${GUARD_HITS_LOG}"
    ( cd "${run_dir}" && printf '%s' "${json}" | bash "${HOOKS_DIR}/${hook}" >/dev/null 2>&1 )
    if [ ! -f "${GUARD_HITS_LOG}" ]; then
        PASS=$((PASS + 1)); echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  NG: ${desc}（許可なのに記録された）"
    fi
}

check_logged "grep ブロックを記録する" "grep-blocked" guard-bash-command.sh "$(bash_json "grep foo bar.txt")"
check_logged "素の rm ブロックを記録する" "bare-rm-blocked" guard-bash-command.sh "$(bash_json "rm foo.txt")"
check_not_logged "fd 許可は記録しない" guard-bash-command.sh "$(bash_json "fd -e go")"
check_not_logged "command rm 許可は記録しない" guard-bash-command.sh "$(bash_json "command rm -f foo")"

# レビューゲート: 通過記録を消して未レビュー状態に戻してから確認する
command rm -f "${gated_git_dir}/claude-reviewed-sha"
check_logged "レビューゲートブロックを記録する" "review-gate-blocked" guard-review-push.sh "$(bash_json "git push")" "${REPO_GATED}"

check_logged "test-skip ブロックを記録する" "test-skip-blocked" guard-test-skip.sh "$(edit_json "foo_test.go" "t.Sk""ip(\"x\")")"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
