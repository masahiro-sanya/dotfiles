#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash / 対人送信系 MCP ツール)
# 「特定の人に呼びかける操作」をブロックし、本文と宛先をユーザーに提示して
# 承認を得てから送らせる。
#
# ブロックする:
#   - GitHub のコメント・レビュー返信（gh pr/issue comment、gh pr review、gh api、GraphQL）
#   - GitHub のレビュー依頼・アサイン（--add-reviewer / --add-assignee 等）
#   - Slack の送信のうち、本文にメンションを含むもの と DM 宛のもの
#   - Notion のコメント
#   - メール送信
# 通す:
#   - 読み取り系すべて（gh pr view / diff、slack_read_*、notion-fetch 等）
#   - gh pr create / gh issue create（レビュー依頼フラグを伴わないもの）
#   - メンションなしの Slack チャンネル投稿・リアクション・canvas
#   - gh pr/issue comment のうち、本文が bot 宛だけのもの（/review 等のスラッシュコマンド、
#     @claude / @gemini 等の bot メンション）。人に届く呼びかけではないため。
#     人へのメンションが 1 つでも混ざれば従来どおりブロックする。
#     gh pr review（PR 作者宛のレビュー提出）と gh api 経由のレビュー返信は人宛なので例外にしない。
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
    # mtime の取り方が BSD(macOS) と GNU(Linux) で違う。GNU stat は -f を
    # --file-system と解釈して %m にマウントポイント（"/" 等）を返し、exit 0 で
    # 成功してしまうので、`||` のフォールバックだけでは拾えない。
    # 数字が返ったかで判定し、駄目ならもう一方を試す。
    _mt="$(/usr/bin/stat -f %m "${OUTBOUND_OK_MARKER}" 2>/dev/null || true)"
    case "${_mt}" in
        ''|*[!0-9]*) _mt="$(/usr/bin/stat -c %Y "${OUTBOUND_OK_MARKER}" 2>/dev/null || echo 0)" ;;
    esac
    /bin/rm -f "${OUTBOUND_OK_MARKER}" 2>/dev/null || true
    case "${_now}${_mt}" in *[!0-9]*|'') return 1 ;; esac
    [ "${_now}" -ge "${_mt}" ] || return 1
    [ $((_now - _mt)) -lt "${OUTBOUND_OK_TTL}" ] || return 1
    return 0
}

# ヒアドキュメント本文を落とす（stdin → stdout）。
# コミットメッセージや PR 本文はコマンドではないのに、tool_input.command には
# 丸ごと入ってくる。判定の grep は行単位に効くので、本文中の "gh pr create" 等の
# 行が実コマンドとして誤検知される（実際に自リポのコミットをブロックした）。
strip_heredocs() {
    _delim=''
    while IFS= read -r _line || [ -n "${_line}" ]; do
        if [ -n "${_delim}" ]; then
            # 終端行（<<- 用に先頭タブ/空白を許容）まで本文として捨てる
            case "$(printf '%s' "${_line}" | /usr/bin/sed 's/^[[:space:]]*//')" in
                "${_delim}") _delim='' ;;
            esac
            continue
        fi
        printf '%s\n' "${_line}"
        # <<EOF / <<'EOF' / <<-"EOF" の開始を拾う（herestring <<< は対象外）
        _d="$(printf '%s\n' "${_line}" \
            | /usr/bin/sed -nE "s/.*(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*).*/\\2/p")"
        [ -n "${_d}" ] && _delim="${_d}"
    done
}

# ---- GitHub コメントの bot 宛判定 ----
# レビュー bot を呼ぶだけのコメント（/review、@claude 等）は人への呼びかけではないので通す。
# 許可するハンドルはここだけで定義する。テスト用に env で差し替え可。
OUTBOUND_BOT_HANDLES="${OUTBOUND_BOT_HANDLES:-claude|claude-bot|gemini|gemini-code-assist|codex|copilot|github-actions|coderabbitai|cursor|devin-ai-integration}"

# コマンド文字列から --body / -b の値を取り出す。中身を読めないとき（--body-file、
# コマンド置換、フラグ自体が無い＝エディタ起動）は return 1 で「判定不能」を返し、
# 呼び出し側はブロックに倒す。
gh_comment_body() {
    _c="$1"
    # ファイル渡し（--body-file / -F）は中身が見えない
    printf '%s\n' "${_c}" | /usr/bin/grep -qE '(--body-file|(^|[[:space:]])-F([[:space:]]|=))' && return 1
    # 本文が 2 つ以上（&& で複数コメントを連結など）だと先頭しか見えず、後続を見逃す
    [ "$(printf '%s\n' "${_c}" | /usr/bin/grep -oE '(^|[[:space:]])(--body|-b)([[:space:]]|=)' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = "1" ] || return 1
    # 引用は 'x' → "x" → 素のトークン の順に試す。負の文字クラスは改行も食うので複数行本文も取れる。
    # 末尾に空白/行末を要求するのが肝: これが無いと "@claude "'cc @alice' のような
    # クォート連結やエスケープ引用符で本文の前半だけを抜き出してしまい、後半の人宛
    # メンションを見落とす（＝バイパスされる）。読み切れない形は下の return 1 に落とす
    _re_sq="(--body|-b)[[:space:]]*=?[[:space:]]*'([^']*)'([[:space:]]|$)"
    _re_dq="(--body|-b)[[:space:]]*=?[[:space:]]*\"([^\"]*)\"([[:space:]]|$)"
    _re_bare="(--body|-b)[[:space:]]*=?[[:space:]]*([^[:space:]'\"]+)([[:space:]]|$)"
    if [[ "${_c}" =~ ${_re_sq} ]]; then
        _body="${BASH_REMATCH[2]}"
    elif [[ "${_c}" =~ ${_re_dq} ]]; then
        _body="${BASH_REMATCH[2]}"
    elif [[ "${_c}" =~ ${_re_bare} ]]; then
        _body="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    # 展開結果が実行時にしか決まらないものは中身を判定できない。
    # $( ${ だけでなく素の $VAR も対象（展開後に人宛メンションが混ざりうる）
    case "${_body}" in *'$'*|*'`'*) return 1 ;; esac
    printf '%s' "${_body}"
    return 0
}

# 本文が bot 宛だけなら return 0。人へのメンションが混ざる／合図が無いときは return 1。
gh_body_is_bot_only() {
    _b="$1"
    [ -n "${_b}" ] || return 1
    # 本文中の @ハンドルを全部拾う。直前がメールアドレスの一部（英数.+-）なら誤爆させない
    _mentions="$(printf '%s\n' "${_b}" \
        | /usr/bin/grep -oE '(^|[^A-Za-z0-9_.+-])@[A-Za-z0-9][A-Za-z0-9-]*' \
        | /usr/bin/sed 's/.*@//')"
    # 1 つでも許可リスト外があれば人宛として扱う
    for _m in ${_mentions}; do
        printf '%s' "${_m}" | /usr/bin/grep -qiE "^(${OUTBOUND_BOT_HANDLES})$" || return 1
    done
    [ -n "${_mentions}" ] && return 0
    # メンションが無い場合は、先頭行がスラッシュコマンド（/review 等）のときだけ bot 宛とみなす。
    # 素の本文（"LGTM" 等）は人が読むコメントなので通さない
    printf '%s\n' "${_b}" | /usr/bin/sed -n '/[^[:space:]]/{p;q;}' \
        | /usr/bin/grep -qE '^[[:space:]]*/[A-Za-z][A-Za-z0-9_-]*([[:space:]]|$)' && return 0
    return 1
}

# ---- 判定: コマンド文字列 ----
# 対人送信なら "分類<TAB>理由" を stdout に出して return 0、非該当は return 1。
classify_command() {
    _cmd="$(printf '%s\n' "$1" | strip_heredocs)"
    [ -z "${_cmd}" ] && return 1

    # コマンド位置の gh / gog だけを見る（echo やコミットメッセージ中の文字列で誤爆させない）
    _cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*'
    _gh_opts='([[:space:]]+(-R|--repo)[[:space:]]+[^[:space:]]+)?'

    # gh pr comment / gh issue comment（＝人が読むコメント）
    # 本文が bot 宛だけ（/review 等のスラッシュコマンド、@claude/@gemini 等の bot メンション）なら
    # 人への呼びかけではないので通す。本文を読めないときは判定不能＝ブロックに倒す
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE "${_cmd_pos}gh${_gh_opts}[[:space:]]+(pr|issue)[[:space:]]+comment([[:space:]]|$)"; then
        # 通すときも return せず後続の判定を続ける（&& で他の対人操作を連結されうるため）
        if ! { _body="$(gh_comment_body "${_cmd}")" && gh_body_is_bot_only "${_body}"; }; then
            printf 'gh-pr-issue-write\tレビューコメント・返信です。勝手に返信しないこと。本文をユーザーに提示して承認を得てください。\n'
            return 0
        fi
    fi

    # gh pr review は PR 作者宛のレビュー提出なので bot 宛の例外を作らない
    # gh pr create / gh issue create は自分の成果物の提出で、レビュー依頼フラグが
    # 付かない限り特定の人への呼びかけではないため通す（下の --add-reviewer 判定で拾う）
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE "${_cmd_pos}gh${_gh_opts}[[:space:]]+pr[[:space:]]+review([[:space:]]|$)"; then
        printf 'gh-pr-issue-write\tレビュー提出です。勝手に返信しないこと。本文をユーザーに提示して承認を得てください。\n'
        return 0
    fi

    # gh pr edit --add-reviewer など、他の人を巻き込むフラグ。
    # gh 本体とフラグが同じ行にあることを 1 つの正規表現で要求する（別々の grep を
    # 全体にかけると、離れた行の断片同士が組み合わさって誤爆する）
    if printf '%s\n' "${_cmd}" | /usr/bin/grep -qE \
        "${_cmd_pos}gh${_gh_opts}[[:space:]]+(pr|issue)[[:space:]]+[^|;&]*(--add-reviewer|--add-assignee|--reviewer|--assignee)([[:space:]]|=|$)"; then
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

# ---- 判定: MCP ツール ----
# plugin 名を含むプレフィックスは環境で変わりうるので mcp__.*<service>.*__ で受ける。
# $1=ツール名 $2=hook への入力 JSON 全体
classify_mcp() {
    _tool="$1"
    _in="$2"

    if printf '%s\n' "${_tool}" | /usr/bin/grep -qE '^mcp__.*slack.*__slack_(send_message|send_message_draft|schedule_message)$'; then
        # DM 判定: channel_id にユーザー ID（U/W 始まり）や DM チャンネル ID（D 始まり）を
        # 渡すと本人への直接送信になる。チャンネル ID（C 始まり）は対象外。
        _chan="$(printf '%s' "${_in}" | /usr/bin/jq -r '.tool_input.channel_id // empty' 2>/dev/null)"
        if printf '%s\n' "${_chan}" | /usr/bin/grep -qE '^[UWD][A-Z0-9]{4,}$'; then
            printf 'slack-dm\tSlack の DM は相手に直接届きます。宛先と本文をユーザーに提示して承認を得てください。\n'
            return 0
        fi
        # メンション判定: 本文キー名（message）に依存すると、キーが変わったとき
        # メンション付きが素通りする＝送信側に倒れる。tool_input 内の全文字列を対象にする。
        _text="$(printf '%s' "${_in}" | /usr/bin/jq -r '[.tool_input | .. | strings] | join(" ")' 2>/dev/null)"
        # <@U…>（ユーザー）/ <!here|channel|everyone|subteam…>（一斉呼び出し）/
        # 素の @xxx（API 経由で通知にならない場合でも、人への呼びかけとして扱う）
        if printf '%s\n' "${_text}" | /usr/bin/grep -qE '(<@[A-Z0-9]+>|<!(here|channel|everyone|subteam)|(^|[[:space:]([])@[A-Za-z0-9])'; then
            printf 'slack-mention\tSlack で人にメンションしています。宛先と本文をユーザーに提示して承認を得てください。\n'
            return 0
        fi
        return 1
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
        if hit="$(classify_mcp "${tool}" "${input}")"; then
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
