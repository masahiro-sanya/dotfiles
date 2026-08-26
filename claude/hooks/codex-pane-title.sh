#!/usr/bin/env bash
# codex のプロンプトを herdr のペインタイトル（表示専用メタデータ）に流す。
#
# なぜ要るか:
#  codex は端末タイトルを cwd のリポ名にしか設定しない（例: "my-repo"）。
#  herdr の agents 一覧は 1 行目に workspace 名を出すので、2 行目に
#  terminal_title を出しても同じ文字列が 2 回並ぶだけで、どのセッションが
#  何をしているのか見分けが付かない。claude は自分でセッションの要約を
#  タイトルに出すため、この hook は要らない（codex 専用）。
#
# 何をするか:
#  UserPromptSubmit のプロンプト先頭行を切り詰めて
#  `herdr pane report-metadata` に渡す。SessionStart / SessionEnd で消す。
#  title と token=title の両方に同じ値を入れる。herdr 側の表示は
#  sidebar の rows_by_agent 設定次第で terminal_title 系にも $title にも
#  向けられるため、どちらの書き方でも拾えるようにしてある。
#
# なぜ OSC でタイトルを書き換えないか（重要）:
#  herdr は codex の稼働状態を「端末タイトルのスピナー」で判定している
#  （agent explain の rule=osc_title_working / evidence="⠹ <リポ名>"）。
#  こちらが OSC 2 でタイトルを上書きすると、この判定が壊れて agents 一覧の
#  状態表示（idle/working）が死ぬ。表示専用メタデータならこの経路に触らない。
#
# 設計方針（このリポの hooks 共通ルール）:
#  - fail-open: 何があっても exit 0。異常は ~/.claude/hooks-error.log に痕跡。
#  - stdout には一切書かない（UserPromptSubmit の stdout はプロンプトに注入される）。
#  - herdr の外（HERDR_ENV≠1）では完全に no-op。
#  - macOS 標準 bash 3.2 互換。変数展開は ${var} 形式。
#
# テスト用フック(env で差し替え):
#  - HERDR_BIN : herdr コマンド（既定 herdr）
#  - HOOKS_ERROR_LOG : 異常痕跡ログの書き先（既定 ~/.claude/hooks-error.log）
set -u

# 表示幅ではなく文字数で切る。サイドバー幅は可変なので、長すぎるものを
# 落とすのが目的で、ぴったり合わせる必要はない。
TITLE_MAX=40
# メタデータの報告元 ID。herdr は source ごとに値を持つので、他の報告者
# （herdr 自身の codex 連携など）と衝突しない名前にする。
SOURCE_ID="dotfiles:codex-title"

log_err() {
    printf '%s codex-pane-title: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" "$1" \
        >> "${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}" 2>/dev/null
}

# herdr の外では何もしない
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0

herdr_bin="${HERDR_BIN:-herdr}"
command -v "${herdr_bin}" >/dev/null 2>&1 || exit 0

# hook JSON を stdin から読む（端末直叩き等で stdin が tty のときは読まない）
input=""
if [ ! -t 0 ]; then
    input="$(cat 2>/dev/null)"
fi

# イベント名は登録側が第1引数で渡す。無ければ JSON から拾う。
event="${1:-}"
if [ -z "${event}" ] && [ -n "${input}" ] && command -v jq >/dev/null 2>&1; then
    event="$(printf '%s' "${input}" | jq -r '.hook_event_name // ""' 2>/dev/null)"
fi

case "${event}" in
    SessionStart|SessionEnd)
        # セッションの切れ目で消す。ペインを使い回したとき、前のセッションの
        # タイトルが残り続けるのを防ぐ。codex が SessionEnd を出すかは版に
        # よるので、確実に出る SessionStart 側でも消す（次の起動で必ず消える）。
        if ! "${herdr_bin}" pane report-metadata "${HERDR_PANE_ID}" \
            --source "${SOURCE_ID}" --clear-title --clear-token title >/dev/null 2>&1; then
            log_err "clear-title failed (pane=${HERDR_PANE_ID})"
        fi
        exit 0
        ;;
    UserPromptSubmit) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
[ -n "${input}" ] || exit 0

# プロンプトの先頭行（空白行は飛ばす）を 1 行に潰して切り詰める。
# フィールド名は codex の版で揺れうるので候補を順に見る（fail-open）。
title="$(printf '%s' "${input}" | jq -r --argjson max "${TITLE_MAX}" '
    (.prompt // .user_prompt // .input // .message // "")
    | if type == "array" then (map(select(type == "string")) | join(" ")) else . end
    | if type == "string" then . else "" end
    | split("\n")
    | map(select(test("[^[:space:]]")))
    | (.[0] // "")
    | sub("^[[:space:]]+"; "")
    | sub("[[:space:]]+$"; "")
    | gsub("[[:space:]]+"; " ")
    | if (length > $max) then (.[0:($max - 1)] + "…") else . end
' 2>/dev/null)"

[ -n "${title}" ] || exit 0

if ! "${herdr_bin}" pane report-metadata "${HERDR_PANE_ID}" \
    --source "${SOURCE_ID}" --title "${title}" --token title="${title}" >/dev/null 2>&1; then
    log_err "report-metadata failed (pane=${HERDR_PANE_ID})"
fi

exit 0
