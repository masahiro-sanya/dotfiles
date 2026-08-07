#!/usr/bin/env bash
# claude/hooks の回帰テスト（bats 不要・macOS bash 3.2 互換）
# 使い方: bash claude/hooks/tests/run-tests.sh
# 各ケース: PreToolUse 相当の JSON を stdin から hook に流し、exit code を検証する
#
# 注意: skip パターンのフィクスチャは "t.Sk""ip(" のようにシェル連結で分割してある。
# このファイル自体が guard-test-skip.sh の検知対象パス（tests/）にあるため、
# リテラルで書くと編集がガードにブロックされる（実行時には連結されて完全な文字列になる）。

set -u

# git 由来の環境変数を落としてからフィクスチャを作る。
# .githooks/pre-commit からこのテストが走るとき、git は GIT_DIR / GIT_INDEX_FILE 等を
# 環境に置く。これらは引数のパスより優先されるため、make_repo の `git init <path>` や
# `git -C <path> commit` が一時ディレクトリでなく dotfiles リポ本体に着弾する
# （実際に main へ空コミットが4つ積まれ、feat/test が生え、core.bare=true にされた）。
# guard 側も PWD でなく GIT_DIR のブランチを見てしまい、branch 判定のテストが誤って落ちる。
for _v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "${_v}"
done
unset _v

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'command rm -rf "${TMP_ROOT}"' EXIT

# ブロック発火テレメトリのログを本物（~/.claude/guard-hits.log）でなくテスト用に向ける
export GUARD_HITS_LOG="${TMP_ROOT}/guard-hits.log"
# fail-open の痕跡ログも本物（~/.claude/hooks-error.log）でなくテスト用に向ける
# （テスト実行で本物のログを汚さない・fail-open 診断の記録内容を検証できるようにする）
export HOOKS_ERROR_LOG="${TMP_ROOT}/hooks-error.log"

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
assert 2 guard-bash-command.sh "&& 後の grep はブロック" "$(bash_json "cd /tmp && grep -rn foo src/")"
assert 0 guard-bash-command.sh "git grep は許可（コマンド位置でない）" "$(bash_json "git grep foo")"
assert 0 guard-bash-command.sh "引数中の grep は許可" "$(bash_json "rg -n 'use grep here' docs/")"
assert 2 guard-bash-command.sh "find はブロック" "$(bash_json "find . -name '*.go'")"
assert 0 guard-bash-command.sh "fd は許可" "$(bash_json "fd -e go")"

# パイプの受け側の grep は許可する（別コマンドの出力の絞り込み＝ rg に替えても効果がない）。
# find は stdin を読まずファイルシステムを見るため、パイプ後でもブロックを続ける。
assert 0 guard-bash-command.sh "パイプ先の grep は許可" "$(bash_json "cat a.txt | grep foo")"
assert 0 guard-bash-command.sh "rg の結果を grep で絞るのは許可" "$(bash_json "rg -n Consent --type kt | grep -v Test")"
assert 0 guard-bash-command.sh "git show を grep で絞るのは許可" "$(bash_json "git show HEAD | grep -c added")"
assert 2 guard-bash-command.sh "パイプ先の find はブロック（stdin を読まない）" "$(bash_json "echo x | find . -name '*.go'")"

# クォート内の | をパイプと誤認しない（rg のパターンに | を書いただけで誤爆していた）
assert 0 guard-bash-command.sh "引用符内の | と grep は許可" "$(bash_json "rg -n 'foo|grep bar' docs/")"
assert 0 guard-bash-command.sh "引用符内の | と find は許可" "$(bash_json "rg -n \"a|find b\" docs/")"

# リモートシェル（rg/fd が無い）の内側は、クォート除去とコマンド位置判定の結果として
# 素通りする。専用の除外条件は置かない（置くとガード全体の迂回路になるため。下の回帰参照）
assert 0 guard-bash-command.sh "adb shell 内の grep は許可（クォート内）" "$(bash_json "adb shell \"dumpsys activity | grep -E top\"")"
assert 0 guard-bash-command.sh "docker compose exec の grep は許可（コマンド位置でない）" "$(bash_json "docker compose exec -T app grep -rl Trtc tests/")"
assert 0 guard-bash-command.sh "docker exec 内の find は許可（コマンド位置でない）" "$(bash_json "docker exec palmu-api find /var/www -name '*.php'")"
assert 0 guard-bash-command.sh "kubectl exec 内の grep は許可（コマンド位置でない）" "$(bash_json "kubectl exec pod -- grep foo /etc/hosts")"

# 回帰: リモートシェル語彙を含む行でも、区切りの後のローカル grep/find はブロックし続ける
# （「行に ssh/docker exec があればスキップ」という除外を入れるとここが素通りする）
assert 2 guard-bash-command.sh "ssh の後に && で繋いだローカル grep はブロック" "$(bash_json "ssh host true && grep -rn secret .")"
assert 2 guard-bash-command.sh "docker exec の後に ; で繋いだローカル grep はブロック" "$(bash_json "docker compose exec app true; grep -rn foo src/")"
assert 2 guard-bash-command.sh "kubectl exec の後に繋いだローカル find はブロック" "$(bash_json "kubectl exec pod -- true && find . -name '*.go'")"

# 回帰: || は論理 OR（独立コマンド）なのでパイプ受け側の許可対象に含めない
assert 2 guard-bash-command.sh "|| の後の grep はブロック" "$(bash_json "false || grep -rn pattern src/")"
assert 2 guard-bash-command.sh "|| の後の find はブロック" "$(bash_json "true || find . -name '*.go'")"

assert 2 guard-bash-command.sh "ローカルの grep は従来どおりブロック" "$(bash_json "grep -rn pattern src/")"
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

# 監査ログ改変防止（guard-hits / hooks-error / logs/traces）
assert 2 guard-bash-command.sh "監査ログの command rm はブロック" "$(bash_json "command rm -f ~/.claude/guard-hits.log")"
assert 2 guard-bash-command.sh "trace ログディレクトリの rm -rf はブロック" "$(bash_json "command rm -rf ~/.claude/logs/traces")"
assert 2 guard-bash-command.sh "監査ログの mv はブロック" "$(bash_json "mv ~/.claude/hooks-error.log /tmp/x")"
assert 2 guard-bash-command.sh "truncate はブロック" "$(bash_json "truncate -s 0 ~/.claude/guard-hits.log")"
assert 2 guard-bash-command.sh "tee 上書きはブロック" "$(bash_json "echo x | tee ~/.claude/guard-hits.log")"
assert 2 guard-bash-command.sh "上書きリダイレクトはブロック" "$(bash_json "echo x > ~/.claude/guard-hits.log")"
assert 2 guard-bash-command.sh "noclobber 上書き（>|）もブロック" "$(bash_json "echo x >| ~/.claude/hooks-error.log")"
assert 0 guard-bash-command.sh "監査ログの読み取りは許可" "$(bash_json "cat ~/.claude/guard-hits.log")"
assert 0 guard-bash-command.sh "監査ログへの追記（>>）は許可" "$(bash_json "echo note >> ~/.claude/hooks-error.log")"
assert 0 guard-bash-command.sh "監査ログのバックアップ cp は許可" "$(bash_json "cp ~/.claude/guard-hits.log /tmp/backup.log")"
assert 0 guard-bash-command.sh "別セグメントの rm と監査ログ読みの複合は許可" "$(bash_json "command rm -f /tmp/x && cat ~/.claude/guard-hits.log")"

# --dangerously-skip-permissions（Light ガイドライン）
assert 2 guard-bash-command.sh "dangerously-skip-permissions はブロック" "$(bash_json "claude --dangerously-skip-permissions -p task")"
assert 0 guard-bash-command.sh "引用符内の dangerously-skip 言及は許可" "$(bash_json "echo 'never use --dangerously-skip-permissions'")"

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

echo "== guard-outbound-comms.sh =="

# 承認マーカーは本物（~/.claude/outbound-ok）でなくテスト用に向ける
export OUTBOUND_OK_MARKER="${TMP_ROOT}/outbound-ok"

# oc_bash <command> : Bash ツールのペイロード
oc_bash() {
    /usr/bin/jq -cn --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

# oc_mcp <tool_name> : MCP ツールのペイロード（引数を見ないツール用）
oc_mcp() {
    /usr/bin/jq -cn --arg t "$1" '{tool_name: $t, tool_input: {}}'
}

# oc_slack <tool_name> <channel_id> <message> : Slack 送信のペイロード
oc_slack() {
    /usr/bin/jq -cn --arg t "$1" --arg c "$2" --arg m "$3" \
        '{tool_name: $t, tool_input: {channel_id: $c, message: $m}}'
}

# GitHub: 人への返信・レビュー依頼はブロック
assert 2 guard-outbound-comms.sh "gh pr comment はブロック" "$(oc_bash "gh pr comment 123 --body LGTM")"
assert 2 guard-outbound-comms.sh "gh pr review はブロック" "$(oc_bash "gh pr review 12 --comment -b fix")"
assert 2 guard-outbound-comms.sh "gh issue comment はブロック" "$(oc_bash "gh issue comment 5 --body ok")"
assert 2 guard-outbound-comms.sh "-R 付きでもブロック" "$(oc_bash "gh -R owner/repo pr comment 1 --body x")"
assert 2 guard-outbound-comms.sh "レビュー依頼（--add-reviewer）はブロック" "$(oc_bash "gh pr edit 3 --add-reviewer foo")"
assert 2 guard-outbound-comms.sh "PR 作成でも --reviewer 付きはブロック" "$(oc_bash "gh pr create --title x --reviewer foo")"
assert 2 guard-outbound-comms.sh "gh api の replies POST はブロック" "$(oc_bash "gh api repos/o/r/pulls/1/comments/9/replies -X POST -f body=hi")"
assert 2 guard-outbound-comms.sh "GraphQL の addComment はブロック" "$(oc_bash "gh api graphql -f query='mutation { addComment(input: {}) { id } }'")"
assert 2 guard-outbound-comms.sh "メール送信はブロック" "$(oc_bash "gogcli.sh gmail send --to a@example.com")"

# 読み取り・無関係コマンドは素通り（誤爆させない）
assert 0 guard-outbound-comms.sh "gh pr create は許可（自分の成果物の提出）" "$(oc_bash "gh pr create --title x --body y")"
assert 0 guard-outbound-comms.sh "gh issue create は許可" "$(oc_bash "gh issue create --title x --body y")"
assert 0 guard-outbound-comms.sh "gh pr view --json comments は許可" "$(oc_bash "gh pr view 123 --json comments")"
assert 0 guard-outbound-comms.sh "gh pr diff は許可" "$(oc_bash "gh pr diff 123")"
assert 0 guard-outbound-comms.sh "gh api の GET は許可" "$(oc_bash "gh api repos/o/r/pulls/1/comments")"
assert 0 guard-outbound-comms.sh "GraphQL の読み取りクエリは許可（reviews/comments を含んでも）" \
    "$(oc_bash "gh api graphql -f query='{ repository { pullRequests { reviews { comments } } } }'")"
assert 0 guard-outbound-comms.sh "コミットメッセージ中の文字列は許可" "$(oc_bash "git commit -m 'reply to review comment'")"
assert 0 guard-outbound-comms.sh "echo 中の gh pr comment は許可" "$(oc_bash "echo gh pr comment")"
assert 0 guard-outbound-comms.sh "無関係なコマンドは許可" "$(oc_bash "ls -la")"

# GitHub コメントのうち bot 宛だけのものは許可（人への呼びかけではないため）
assert 0 guard-outbound-comms.sh "スラッシュコマンドだけのコメントは許可" "$(oc_bash "gh pr comment 123 --body '/review'")"
assert 0 guard-outbound-comms.sh "bot メンションだけのコメントは許可" "$(oc_bash "gh pr comment 123 --body '@claude このPRをレビューして'")"
assert 0 guard-outbound-comms.sh "issue でも bot 宛なら許可" "$(oc_bash "gh issue comment 5 --body '@gemini-code-assist review'")"
assert 0 guard-outbound-comms.sh "-R 付きでも bot 宛なら許可" "$(oc_bash "gh -R owner/repo pr comment 1 --body '@claude review'")"

# 人が絡むものは従来どおりブロック
assert 2 guard-outbound-comms.sh "人へのメンションはブロック" "$(oc_bash "gh pr comment 1 --body '@alice 見てもらえますか'")"
assert 2 guard-outbound-comms.sh "bot と人が混ざればブロック" "$(oc_bash "gh pr comment 1 --body '@claude review cc @alice'")"
assert 2 guard-outbound-comms.sh "メンションなしの素の本文はブロック" "$(oc_bash "gh pr comment 1 --body 'ここは直しました'")"
assert 2 guard-outbound-comms.sh "gh pr review は bot 宛でもブロック" "$(oc_bash "gh pr review 12 --comment --body '@claude review'")"

# 本文を読めないものは判定不能＝ブロックに倒す
assert 2 guard-outbound-comms.sh "--body-file はブロック" "$(oc_bash "gh pr comment 1 --body-file /tmp/body.md")"
assert 2 guard-outbound-comms.sh "コマンド置換の本文はブロック" "$(oc_bash 'gh pr comment 1 --body "$(cat body.md)"')"
assert 2 guard-outbound-comms.sh "素の変数展開を含む本文はブロック" "$(oc_bash 'gh pr comment 1 --body "@claude $NOTE"')"
assert 2 guard-outbound-comms.sh "クォート連結で人宛を隠しても抽出せずブロック" \
    "$(oc_bash "gh pr comment 1 --body \"@claude \"'cc @alice よろしく'")"
assert 2 guard-outbound-comms.sh "エスケープ引用符を含む本文はブロック" \
    "$(oc_bash 'gh pr comment 1 --body "@claude \"@alice にも共有\""')"
assert 2 guard-outbound-comms.sh "本文フラグなし（エディタ起動）はブロック" "$(oc_bash "gh pr comment 1")"
assert 2 guard-outbound-comms.sh "コメントを連結したら人宛が混ざりうるのでブロック" \
    "$(oc_bash "gh pr comment 1 --body '/review' && gh pr comment 2 --body '@alice hi'")"
assert 2 guard-outbound-comms.sh "bot 宛コメントに他の対人操作を連結してもブロック" \
    "$(oc_bash "gh pr comment 1 --body '/review' ; gh pr edit 2 --add-reviewer alice")"

# ヒアドキュメント本文（コミットメッセージ・PR 本文）はコマンドではないので判定対象外。
# 本文中の gh 文字列で実際にコミットがブロックされた回帰テスト
heredoc_msg="git commit -F - <<'MSGEOF'
fix(hooks): ガードの範囲を絞る

- gh pr create / gh issue create は通す
- --reviewer が付く場合は従来どおりブロック
MSGEOF"
assert 0 guard-outbound-comms.sh "ヒアドキュメント本文の gh 文字列で誤爆しない" "$(oc_bash "${heredoc_msg}")"

# ただし終端行より後ろは実コマンドなので、そこは従来どおり判定する
heredoc_then_cmd="git commit -F - <<'MSGEOF'
本文
MSGEOF
gh pr comment 1 --body x"
assert 2 guard-outbound-comms.sh "ヒアドキュメントの後ろのコマンドは判定する" "$(oc_bash "${heredoc_then_cmd}")"

# 複数行の GraphQL mutation は実コマンドなのでブロックしたまま
graphql_multiline="gh api graphql -f query='
  mutation {
    addComment(input: {subjectId: \"x\", body: \"y\"}) { clientMutationId }
  }
'"
assert 2 guard-outbound-comms.sh "複数行 GraphQL の addComment はブロック" "$(oc_bash "${graphql_multiline}")"

# Slack: 本文のメンションと DM 宛だけをブロックする
SLACK_SEND="mcp__plugin_slack_slack__slack_send_message"
assert 2 guard-outbound-comms.sh "ユーザーメンションはブロック" "$(oc_slack "${SLACK_SEND}" "C012345" "<@U04BS3XV5T8> 確認お願いします")"
assert 2 guard-outbound-comms.sh "@here はブロック" "$(oc_slack "${SLACK_SEND}" "C012345" "<!here> リリースします")"
assert 2 guard-outbound-comms.sh "@channel はブロック" "$(oc_slack "${SLACK_SEND}" "C012345" "<!channel> 障害です")"
assert 2 guard-outbound-comms.sh "ユーザーグループ（subteam）はブロック" "$(oc_slack "${SLACK_SEND}" "C012345" "<!subteam^S123|@dev> 見てください")"
assert 2 guard-outbound-comms.sh "素の @名前 もブロック" "$(oc_slack "${SLACK_SEND}" "C012345" "@masahiro 確認お願いします")"
assert 2 guard-outbound-comms.sh "DM 宛（ユーザーID）はブロック" "$(oc_slack "${SLACK_SEND}" "U04BS3XV5T8" "メンションなしの本文")"
assert 2 guard-outbound-comms.sh "DM チャンネル（D始まり）はブロック" "$(oc_slack "${SLACK_SEND}" "D0123456" "メンションなしの本文")"
assert 2 guard-outbound-comms.sh "予約投稿もメンションならブロック" \
    "$(oc_slack "mcp__plugin_slack_slack__slack_schedule_message" "C012345" "<!here> 明日リリース")"
assert 2 guard-outbound-comms.sh "下書きもメンションならブロック" \
    "$(oc_slack "mcp__plugin_slack_slack__slack_send_message_draft" "C012345" "<@U0999> お願いします")"
assert 2 guard-outbound-comms.sh "Notion コメントはブロック" "$(oc_mcp "mcp__notion__notion-create-comment")"

# メンションなしのチャンネル投稿・リアクション・読み取りは通す
assert 0 guard-outbound-comms.sh "メンションなしのチャンネル投稿は許可" "$(oc_slack "${SLACK_SEND}" "C012345" "デプロイが完了しました")"
assert 0 guard-outbound-comms.sh "本文中のメールアドレスは誤爆させない" "$(oc_slack "${SLACK_SEND}" "C012345" "連絡先は a@example.com です")"
assert 0 guard-outbound-comms.sh "Slack リアクションは許可" "$(oc_mcp "mcp__plugin_slack_slack__slack_add_reaction")"
assert 0 guard-outbound-comms.sh "canvas 作成は許可" "$(oc_mcp "mcp__plugin_slack_slack__slack_create_canvas")"
assert 0 guard-outbound-comms.sh "Slack 読み取りは許可" "$(oc_mcp "mcp__plugin_slack_slack__slack_read_channel")"
assert 0 guard-outbound-comms.sh "Slack ユーザー検索は許可" "$(oc_mcp "mcp__plugin_slack_slack__slack_search_users")"
assert 0 guard-outbound-comms.sh "Notion 取得は許可" "$(oc_mcp "mcp__notion__notion-fetch")"
assert 0 guard-outbound-comms.sh "壊れた JSON は fail-open" "{broken json"

# 承認マーカー: 1回で消費され、期限切れは無効
touch "${OUTBOUND_OK_MARKER}"
assert 0 guard-outbound-comms.sh "承認マーカーがあれば通す" "$(oc_bash "gh pr comment 1 --body x")"
assert 2 guard-outbound-comms.sh "マーカーは1回で消費される（2回目はブロック）" "$(oc_bash "gh pr comment 1 --body x")"
touch "${OUTBOUND_OK_MARKER}"
assert 0 guard-outbound-comms.sh "承認マーカーは Slack メンションにも効く" "$(oc_slack "${SLACK_SEND}" "C012345" "<!here> 告知")"

# 11分前のマーカー（TTL 10分超）は無効。BSD(macOS) / GNU(CI) 両対応で mtime を戻す
touch "${OUTBOUND_OK_MARKER}"
touch -t "$(date -v-11M +%Y%m%d%H%M 2>/dev/null || date -d '11 minutes ago' +%Y%m%d%H%M 2>/dev/null || date +%Y%m%d%H%M)" \
    "${OUTBOUND_OK_MARKER}" 2>/dev/null
assert 2 guard-outbound-comms.sh "期限切れマーカーは無効" "$(oc_bash "gh pr comment 1 --body x")"
if [ ! -f "${OUTBOUND_OK_MARKER}" ]; then
    PASS=$((PASS + 1)); echo "  ok: 期限切れマーカーは掃除される"
else
    FAIL=$((FAIL + 1)); echo "  NG: 期限切れマーカーが残置された"
fi

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
check_logged "監査ログ改変ブロックを記録する" "audit-log-tamper-blocked" guard-bash-command.sh "$(bash_json "command rm -f ~/.claude/guard-hits.log")"
check_logged "dangerously-skip ブロックを記録する" "dangerously-skip-blocked" guard-bash-command.sh "$(bash_json "claude --dangerously-skip-permissions -p task")"
check_not_logged "fd 許可は記録しない" guard-bash-command.sh "$(bash_json "fd -e go")"
check_not_logged "command rm 許可は記録しない" guard-bash-command.sh "$(bash_json "command rm -f foo")"

# レビューゲート: 通過記録を消して未レビュー状態に戻してから確認する
command rm -f "${gated_git_dir}/claude-reviewed-sha"
check_logged "レビューゲートブロックを記録する" "review-gate-blocked" guard-review-push.sh "$(bash_json "git push")" "${REPO_GATED}"

check_logged "対人送信ブロックを記録する" "gh-pr-issue-write-blocked" guard-outbound-comms.sh "$(oc_bash "gh pr comment 1 --body x")"
check_logged "Slack メンションブロックを記録する" "slack-mention-blocked" guard-outbound-comms.sh "$(oc_slack "${SLACK_SEND}" "C012345" "<!here> x")"
check_logged "Slack DM ブロックを記録する" "slack-dm-blocked" guard-outbound-comms.sh "$(oc_slack "${SLACK_SEND}" "U0123456" "x")"
check_not_logged "gh pr view は記録しない" guard-outbound-comms.sh "$(oc_bash "gh pr view 1")"
check_not_logged "メンションなしの投稿は記録しない" guard-outbound-comms.sh "$(oc_slack "${SLACK_SEND}" "C012345" "デプロイ完了")"

# 承認バイパスも監査できるよう記録する（乱用を後から追えるようにする）
command rm -f "${GUARD_HITS_LOG}"
touch "${OUTBOUND_OK_MARKER}"
check_logged "承認バイパスを記録する" "gh-pr-issue-write-approved" guard-outbound-comms.sh "$(oc_bash "gh pr comment 1 --body x")"

check_logged "test-skip ブロックを記録する" "test-skip-blocked" guard-test-skip.sh "$(edit_json "foo_test.go" "t.Sk""ip(\"x\")")"

echo "== fail-open 診断計装 =="

# 壊れた JSON で fail-open したとき、真因究明用に bytes= と jqerr=（パース位置）が
# hooks-error.log に残ることを確認する。生データは残さない設計なのでキーの有無だけ見る。
# check_diag <説明> <hook> <JSON> [run_dir]
check_diag() {
    desc="$1"; hook="$2"; json="$3"; run_dir="${4:-${TMP_ROOT}}"
    command rm -f "${HOOKS_ERROR_LOG}"
    ( cd "${run_dir}" && printf '%s' "${json}" | bash "${HOOKS_DIR}/${hook}" >/dev/null 2>&1 )
    if [ -f "${HOOKS_ERROR_LOG}" ] \
        && /usr/bin/grep -q 'bytes=' "${HOOKS_ERROR_LOG}" \
        && /usr/bin/grep -q 'jqerr=' "${HOOKS_ERROR_LOG}"; then
        PASS=$((PASS + 1)); echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  NG: ${desc}（bytes=/jqerr= が記録されていない）"
    fi
}

# 正常な JSON（キー不在含む）では fail-open ログを残さない（診断の誤発火防止）
# check_no_diag <説明> <hook> <JSON> [run_dir]
check_no_diag() {
    desc="$1"; hook="$2"; json="$3"; run_dir="${4:-${TMP_ROOT}}"
    command rm -f "${HOOKS_ERROR_LOG}"
    ( cd "${run_dir}" && printf '%s' "${json}" | bash "${HOOKS_DIR}/${hook}" >/dev/null 2>&1 )
    if [ ! -f "${HOOKS_ERROR_LOG}" ]; then
        PASS=$((PASS + 1)); echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  NG: ${desc}（正常入力なのに fail-open ログが出た）"
    fi
}

check_diag "guard-bash-command は壊れた JSON の診断を残す" guard-bash-command.sh "{broken json"
check_diag "guard-review-push は壊れた JSON の診断を残す" guard-review-push.sh "{broken json"
check_diag "guard-test-skip は壊れた JSON の診断を残す（file_path 段）" guard-test-skip.sh "{broken json"
# guard-test-skip の content 段（file_path は valid で通り、content 抽出でパース失敗）は
# 単一 jq 入力なので file_path 段で先に捕捉される。ここでは file_path 段の診断で代表させる。
check_no_diag "正常 JSON では診断を残さない（bash）" guard-bash-command.sh "$(bash_json "ls -la")"
check_no_diag "キー不在の正常 JSON でも診断を残さない（test-skip）" guard-test-skip.sh "$(bash_json "ls -la")"

echo "== wezterm-status.sh =="

# WezTerm タブ状態 hook: hook_event_name を見て pane_id 単位の状態ファイル
#   <WEZTERM_STATE_DIR>/pane-<WEZTERM_PANE>   （中身: busy|waiting|idle|sub:N）
# を書く。tty も WezTerm も要らない。ファイルの中身をそのまま検証する。
WT_DIR="${TMP_ROOT}/wt"
mkdir -p "${WT_DIR}"
WT_PANE="99"                                   # 架空の pane id
WT_STATE_FILE="${WT_DIR}/pane-${WT_PANE}"

# wt_json <event> <session_id> <agent_id> : hook が読む JSON を組み立てる
wt_json() {
    /usr/bin/jq -cn --arg e "$1" --arg s "$2" --arg a "${3:-}" \
        '{hook_event_name: $e, session_id: $s, agent_id: $a}'
}

# run_wt <event> <session_id> <agent_id> : WezTerm 内を模して hook を実行する
run_wt() {
    printf '%s' "$(wt_json "$1" "$2" "$3")" | \
        WEZTERM_PANE="${WT_PANE}" WEZTERM_STATE_DIR="${WT_DIR}" \
        bash "${HOOKS_DIR}/wezterm-status.sh" >/dev/null 2>&1
}

# 状態ファイルの中身を返す。ファイルが無ければ __NONE__（クリア済みと区別するため）
wt_read() {
    if [ -f "${WT_STATE_FILE}" ]; then cat "${WT_STATE_FILE}" 2>/dev/null; else printf '__NONE__'; fi
}

# 同一ペインの状態(表示・メイン・サブ marker)を全消しして各グループを独立させる
wt_reset() {
    command rm -f "${WT_DIR}/pane-${WT_PANE}" "${WT_DIR}/main-${WT_PANE}" \
        "${WT_DIR}/agent-${WT_PANE}-"* 2>/dev/null
}

# assert_state <説明> <期待state> <event> <session_id> [agent_id]
assert_state() {
    desc="$1"; want="$2"; ev="$3"; sess="$4"; aid="${5:-}"
    run_wt "${ev}" "${sess}" "${aid}"
    got="$(wt_read)"
    if [ "${got}" = "${want}" ]; then
        PASS=$((PASS + 1)); echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  NG: ${desc}（expected='${want}', got='${got}'）"
    fi
}

# --- グループ1: メイン turn 状態の遷移（サブ無し）---
wt_reset
assert_state "UserPromptSubmit → busy(実行中)" "busy" "UserPromptSubmit" "s1"
assert_state "Notification → waiting(要対応)" "waiting" "Notification" "s1"
assert_state "Stop → idle(待機中)" "idle" "Stop" "s1"
assert_state "SessionStart → idle(待機中)" "idle" "SessionStart" "s1"

# --- グループ2: 背景サブは親 Stop で消えない（本命の回帰）---
# 親 turn の Stop はサブ稼働中にも発火する。Stop は main を idle にするだけで
# サブ marker は消さないので、サブが全部終わるまで sub:N を保つ。
wt_reset
assert_state "UserPromptSubmit → busy" "busy" "UserPromptSubmit" "s2"
assert_state "SubagentStart a1 → sub:1" "sub:1" "SubagentStart" "s2" "a1"
assert_state "SubagentStart a2 → sub:2" "sub:2" "SubagentStart" "s2" "a2"
assert_state "サブ稼働中の親 Stop でも sub:2 を維持（本命の修正）" "sub:2" "Stop" "s2"
assert_state "SubagentStop a1 → sub:1" "sub:1" "SubagentStop" "s2" "a1"
assert_state "SubagentStop a1 二重発火でも sub:1（idempotent）" "sub:1" "SubagentStop" "s2" "a1"
assert_state "SubagentStop a2 で全終了 → idle" "idle" "SubagentStop" "s2" "a2"

# --- グループ3: 要対応はサブ稼働より優先 ---
wt_reset
assert_state "SubagentStart a1 → sub:1" "sub:1" "SubagentStart" "s3" "a1"
assert_state "サブ稼働中でも Notification は waiting 優先" "waiting" "Notification" "s3"
assert_state "サブ終了後も main=waiting なら waiting" "waiting" "SubagentStop" "s3" "a1"

# --- グループ4: SessionStart はサブ marker を掃除（leak 回復）---
wt_reset
assert_state "SubagentStart a1 → sub:1" "sub:1" "SubagentStart" "s4" "a1"
assert_state "SubagentStart a2 → sub:2" "sub:2" "SubagentStart" "s4" "a2"
assert_state "SessionStart で marker 一掃 → idle" "idle" "SessionStart" "s4"

# --- グループ5: ツール発火も busy の起点（UserPromptSubmit の無いターン）---
# 背景タスクの完了通知で再起動されるターンには UserPromptSubmit が無い。ツール発火を
# busy に繋がないと、Claude が作業している間ずっと待機中と表示される（実測で再現した回帰）。
wt_reset
assert_state "UserPromptSubmit → busy" "busy" "UserPromptSubmit" "s6"
assert_state "SubagentStart a1 → sub:1" "sub:1" "SubagentStart" "s6" "a1"
assert_state "親 Stop でも sub:1" "sub:1" "Stop" "s6"
assert_state "最後のサブ終了 → idle" "idle" "SubagentStop" "s6" "a1"
assert_state "完了通知で再起動→ツール発火で busy（待機中に居座らない）" "busy" "PreToolUse" "s6"

# --- グループ6: 権限プロンプト承認後に waiting が残らない ---
# Notification(waiting) を戻すのが Stop だけだと、承認して作業を続けている間ずっと
# 要対応のままになる。承認後に走るツールの PostToolUse で busy に復帰する。
wt_reset
assert_state "PreToolUse → busy" "busy" "PreToolUse" "s7"
assert_state "権限プロンプト → waiting" "waiting" "Notification" "s7"
assert_state "承認後のツール完了で busy へ復帰（要対応が居座らない）" "busy" "PostToolUse" "s7"

# --- グループ7: サブ稼働中のツール発火は sub:N を壊さない ---
# PreToolUse は busy を書くが、サブが走っていれば表示は sub:N のままであるべき。
wt_reset
assert_state "SubagentStart a1 → sub:1" "sub:1" "SubagentStart" "s8" "a1"
assert_state "サブ稼働中の PreToolUse でも sub:1 を維持" "sub:1" "PreToolUse" "s8"

# --- グループ8: 死んだロックを回収する ---
# hook が timeout で殺されると lock_dir が残り、以降そのペインは毎回スピンし切ってから
# 続行する（実際に pane-47.lock が 8 日間居座っていた）。古いロックは奪って進む。
wt_reset
mkdir -p "${WT_DIR}/pane-${WT_PANE}.lock"
# 31 分前の mtime にして「死んだロック」を作る（30 秒閾値を確実に超える）。
# 「31分前」の算出は OS 差を吸収: BSD(macOS) は date -v-31M、GNU(Linux/CI) は date -d。
# どちらも失敗したときだけ現在時刻（この場合テストは意味を成さないが最後の保険）。
touch -t "$(date -v-31M +%Y%m%d%H%M 2>/dev/null || date -d '31 minutes ago' +%Y%m%d%H%M 2>/dev/null || date +%Y%m%d%H%M)" "${WT_DIR}/pane-${WT_PANE}.lock" 2>/dev/null
assert_state "死んだロックがあっても状態を更新できる" "busy" "UserPromptSubmit" "s9"
if [ ! -d "${WT_DIR}/pane-${WT_PANE}.lock" ]; then
    PASS=$((PASS + 1)); echo "  ok: 死んだロックを回収して解放する"
else
    FAIL=$((FAIL + 1)); echo "  NG: 死んだロックが残置された"
fi

# --- グループ9: SessionEnd は状態ファイルを削除（タブをリポ名だけに戻す）---
wt_reset
assert_state "UserPromptSubmit → busy" "busy" "UserPromptSubmit" "s5"
assert_state "SubagentStart a1 → sub:1" "sub:1" "SubagentStart" "s5" "a1"
assert_state "SessionEnd → 状態ファイル削除(クリア)" "__NONE__" "SessionEnd" "s5"

# --- グループ10: Codex 用エージェントタグ（WEZTERM_STATUS_AGENT=codex）---
# Codex から呼ぶと表示ファイルに "codex:" が前置され、wezterm.lua 側で専用色・バッジに分かれる。
# claude 既定は無印のまま（上のグループ群が後方互換を担保）。Codex は busy/idle/waiting のみ。
run_wt_codex() {
    printf '%s' "$(wt_json "$1" "$2" "$3")" | \
        WEZTERM_PANE="${WT_PANE}" WEZTERM_STATE_DIR="${WT_DIR}" WEZTERM_STATUS_AGENT="codex" \
        bash "${HOOKS_DIR}/wezterm-status.sh" >/dev/null 2>&1
}
assert_state_codex() {
    desc="$1"; want="$2"; ev="$3"; sess="$4"; aid="${5:-}"
    run_wt_codex "${ev}" "${sess}" "${aid}"
    got="$(wt_read)"
    if [ "${got}" = "${want}" ]; then
        PASS=$((PASS + 1)); echo "  ok: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  NG: ${desc}（expected='${want}', got='${got}'）"
    fi
}
wt_reset
assert_state_codex "UserPromptSubmit → codex:busy" "codex:busy" "UserPromptSubmit" "c1"
assert_state_codex "PermissionRequest → codex:waiting（権限待ち）" "codex:waiting" "PermissionRequest" "c1"
assert_state_codex "Stop → codex:idle" "codex:idle" "Stop" "c1"
assert_state_codex "SessionStart → codex:idle" "codex:idle" "SessionStart" "c1"
assert_state_codex "PreToolUse → codex:busy" "codex:busy" "PreToolUse" "c1"
assert_state_codex "busy 中の PostToolUse でも codex:busy（早期抜けで表示維持）" "codex:busy" "PostToolUse" "c1"

# claude 既定（WEZTERM_STATUS_AGENT なし）は無印のまま＝codex タグが漏れない
wt_reset
assert_state "claude 既定は無印 busy（codex タグが漏れない）" "busy" "UserPromptSubmit" "c2"

# 非 WezTerm（WEZTERM_PANE 空）では状態ファイルを作らない・exit 0
command rm -f "${WT_STATE_FILE}"
printf '%s' "$(wt_json "UserPromptSubmit" "s1")" | \
    WEZTERM_PANE='' WEZTERM_STATE_DIR="${WT_DIR}" \
    bash "${HOOKS_DIR}/wezterm-status.sh" >/dev/null 2>&1
wt_ec=$?
if [ "${wt_ec}" -eq 0 ] && [ ! -f "${WT_STATE_FILE}" ]; then
    PASS=$((PASS + 1)); echo "  ok: 非 WezTerm では no-op(ファイル作らず・exit 0)"
else
    FAIL=$((FAIL + 1)); echo "  NG: 非 WezTerm no-op（exit=${wt_ec}, file=$([ -f "${WT_STATE_FILE}" ] && echo あり || echo なし)）"
fi

# 壊れた JSON は fail-open（状態ファイルを作らず exit 0）
command rm -f "${WT_STATE_FILE}"
printf '%s' "{broken json" | \
    WEZTERM_PANE="${WT_PANE}" WEZTERM_STATE_DIR="${WT_DIR}" \
    bash "${HOOKS_DIR}/wezterm-status.sh" >/dev/null 2>&1
wt_ec=$?
if [ "${wt_ec}" -eq 0 ] && [ ! -f "${WT_STATE_FILE}" ]; then
    PASS=$((PASS + 1)); echo "  ok: 壊れた JSON は fail-open(ファイル作らず・exit 0)"
else
    FAIL=$((FAIL + 1)); echo "  NG: 壊れた JSON fail-open（exit=${wt_ec}, file=$([ -f "${WT_STATE_FILE}" ] && echo あり || echo なし)）"
fi

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
