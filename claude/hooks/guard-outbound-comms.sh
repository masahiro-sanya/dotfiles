#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash / 対人送信系 MCP ツール)
# 他の人に届く操作（GitHub のレビュー返信・コメント・PR/Issue 作成・レビュー依頼、
# Slack 投稿・リアクション、Notion コメント、メール送信）をブロックし、
# 本文と宛先をユーザーに提示して承認を得てから送らせる。
# 読み取り系（gh pr view / diff、slack_read_*、notion-fetch 等）は対象外。
#
# 承認後の送り方（ユーザーの承認を得たときだけ）:
#   touch ~/.claude/outbound-ok   # 承認マーカー（10分有効・1回で消費）
#   その直後に同じ操作をやり直す
#
# exit 2 + stderr でブロックする（この環境は permissions.defaultMode="auto" で、
# hook が permissionDecision:"ask" を返しても確認プロンプトが出ない＝素通りするため。
# 実測で gh pr comment / npm install の ask がどちらも無確認で実行された）。

set -u

# fail-open（入力異常で exit 0）する経路の痕跡を残す。ログ失敗で hook 自体は壊さない。
# テスト用に HOOKS_ERROR_LOG で差し替え可。
HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"
log_fail() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') guard-outbound-comms.sh: $1" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
}

# jq が入力パースに失敗したときの診断文字列。生データ（コマンド全文＝機密の恐れ）は残さず、
# 入力バイト数と jq のパースエラー位置だけを残す。
diag_input() {
    _bytes="$(printf '%s' "$1" | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    _jqerr="$(printf '%s' "$1" | /usr/bin/jq -r '.' 2>&1 1>/dev/null | /usr/bin/tr '\t\n' '  ' | /usr/bin/cut -c1-160)"
    printf 'bytes=%s jqerr=[%s]' "${_bytes}" "${_jqerr}"
}

# ブロック／承認バイパスを1行TSVで記録する。誤爆・死物・バイパス乱用を後から追うための
# テレメトリ。ベストエフォート: 記録に失敗してもブロック自体は壊さない。
GUARD_HITS_LOG="${GUARD_HITS_LOG:-${HOME}/.claude/guard-hits.log}"
log_hit() {
    detail="$(printf '%s' "$2" | /usr/bin/tr '\t\n' '  ' | /usr/bin/cut -c1-200)"
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" 'guard-outbound-comms' "$1" "${detail}" \
        >> "${GUARD_HITS_LOG}" 2>/dev/null || true
}

# 承認マーカー: ユーザーの承認後に `touch ~/.claude/outbound-ok` で作る。
# 10分以内に作られたものだけ有効で、1回使うと消える（1承認1送信）。
OUTBOUND_OK_MARKER="${OUTBOUND_OK_MARKER:-${HOME}/.claude/outbound-ok}"
OUTBOUND_OK_TTL="${OUTBOUND_OK_TTL:-600}"
consume_marker() {
    [ -f "${OUTBOUND_OK_MARKER}" ] || return 1
    _now="$(date +%s 2>/dev/null || echo 0)"
    _mt="$(/usr/bin/stat -f %m "${OUTBOUND_OK_MARKER}" 2>/dev/null || /usr/bin/stat -c %Y "${OUTBOUND_OK_MARKER}" 2>/dev/null || echo 0)"
    /bin/rm -f "${OUTBOUND_OK_MARKER}" 2>/dev/null || true
    case "${_now}${_mt}" in *[!0-9]*|'') return 1 ;; esac
    [ "${_now}" -ge "${_mt}" ] || return 1
    [ $((_now - _mt)) -lt "${OUTBOUND_OK_TTL}" ] || return 1
    return 0
}

# ---- 判定: コマンド文字列 ----
# 対人送信なら "分類<TAB>理由" を stdout に出して return 0、非該当は return 1。
classify_command() {
    _cmd="$1"
    [ -z "${_cmd}" ] && return 1

    # コマンド位置の gh / gog だけを見る（echo やコミットメッセージ中の文字列で誤爆させない）
    _cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*'
    _gh_opts='([[:space:]]+(-R|--repo)[[:space:]]+[^[:space:]]+)?'

    # gh pr comment / gh pr review / gh pr create / gh issue comment / gh issue create
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE "${_cmd_pos}gh${_gh_opts}[[:space:]]+(pr|issue)[[:space:]]+(comment|review|create)([[:space:]]|$)"; then
        printf 'gh-pr-issue-write\tレビューコメント・PR/Issue への書き込みです。勝手に返信・投稿しないこと。本文をユーザーに提示して承認を得てください。\n'
        return 0
    fi

    # gh pr edit --add-reviewer など、他の人を巻き込むフラグ
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE "${_cmd_pos}gh${_gh_opts}[[:space:]]+(pr|issue)[[:space:]]+" \
        && printf '%s\n' "${_cmd}" | /usr/bin/grep -qE '(--add-reviewer|--add-assignee|--reviewer|--assignee)([[:space:]]|=|$)'; then
        printf 'gh-request-review\tレビュー依頼・アサインは相手に通知が飛びます。誰に依頼するかユーザーに確認してください。\n'
        return 0
    fi

    # gh api でのコメント/レビュー投稿（fix-pr-reviews の replies エンドポイント等）
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE "${_cmd_pos}gh([[:space:]]+[^[:space:]]+)*[[:space:]]+api([[:space:]]|$)"; then
        if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE '(^|[[:space:]])graphql([[:space:]]|$)'; then
            # GraphQL は query 本文に comments/reviews が普通に出る（読み取りクエリ）ため、
            # エンドポイント名ではなく mutation 名だけで判定する
            if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE '(addComment|addPullRequestReview|submitPullRequestReview|addDiscussionComment|minimizeComment|requestReviews)'; then
                printf 'gh-api-comment\tGraphQL でコメント／レビューを投稿しようとしています。本文をユーザーに提示して承認を得てください。\n'
                return 0
            fi
        elif printf '%s\n' "${_cmd}" | /usr/bin/grep -qE '(comments|reviews|replies|/issues/)' \
            && printf '%s\n' "${_cmd}" | /usr/bin/grep -qE '(-X[[:space:]]*(POST|PATCH|PUT|DELETE)|-{1,2}method[[:space:]]+(POST|PATCH|PUT|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]]|=))'; then
            printf 'gh-api-comment\tgh api でコメント／レビューを投稿しようとしています。本文をユーザーに提示して承認を得てください。\n'
            return 0
        fi
    fi

    # メール送信（gogcli の gmail send）
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE "${_cmd_pos}(gog|gogcli(\.sh)?)([[:space:]]+[^[:space:]]+)*[[:space:]]+gmail[[:space:]]+(send|reply|forward)([[:space:]]|$)"; then
        printf 'mail-send\tメール送信です。宛先と本文をユーザーに確認してください。\n'
        return 0
    fi

    return 1
}

# ---- 判定: MCP ツール名 ----
# plugin 名を含むプレフィックスは環境で変わりうるので mcp__.*<service>.*__ で受ける
classify_tool() {
    _tool="$1"
    if printf '%s\n' "${_tool}" | /usr/bin/grep -qE '^mcp__.*slack.*__slack_(send_message|send_message_draft|schedule_message|create_canvas|update_canvas|add_reaction|create_conversation)$'; then
        printf 'slack-outbound\tSlack で他の人に届く操作です。宛先と本文をユーザーに提示して承認を得てください。\n'
        return 0
    fi
    if printf '%s\n' "${_tool}" | /usr/bin/grep -qE '^mcp__.*notion.*__notion-create-comment$'; then
        printf 'notion-comment\tNotion のコメントは他の人に通知が飛びます。投稿先と本文をユーザーに確認してください。\n'
        return 0
    fi
    return 1
}

# 分類結果（"分類<TAB>理由"）を受けてブロック（または承認済みなら通過）する
# $1="分類<TAB>理由" $2=ログ用の対象要約
decide() {
    _kind="${1%%	*}"
    _reason="${1#*	}"
    if consume_marker; then
        log_hit "${_kind}-approved" "$2"
        exit 0
    fi
    log_hit "${_kind}-blocked" "$2"
    echo "対人送信ガード: ${_reason} 承認を得たら \`touch ~/.claude/outbound-ok\`（10分有効・1回で消費）を実行してから同じ操作をやり直してください。ユーザーの承認なしにこのマーカーを作らないこと。" >&2
    exit 2
}

input="$(cat)"
tool="$(printf '%s' "${input}" | /usr/bin/jq -r '.tool_name // empty' 2>/dev/null)"
jq_status=$?
if [ "${jq_status}" -ne 0 ]; then
    log_fail "jq parse failed (exit ${jq_status}) $(diag_input "${input}")"
    exit 0
fi

case "${tool}" in
    mcp__*)
        # MCP はツール名だけで判定する（引数の形は各サーバー依存なので見ない）
        if hit="$(classify_tool "${tool}")"; then
            decide "${hit}" "tool=${tool}"
        fi
        exit 0
        ;;
esac

cmd="$(printf '%s' "${input}" | /usr/bin/jq -r '.tool_input.command // empty' 2>/dev/null)"
# command キー不在は Bash 以外のペイロード等の正常 skip（ログしない）
[ -z "${cmd}" ] && exit 0

if hit="$(classify_command "${cmd}")"; then
    decide "${hit}" "cmd-head=$(printf '%s' "${cmd}" | /usr/bin/cut -c1-60)"
fi

exit 0
