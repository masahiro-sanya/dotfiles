#!/bin/bash
# herdr-open-session: 別リポの作業を回す先のセッションが無いとき、そのリポの Claude セッションを新しく開いて依頼を渡す
# （claude/CLAUDE.md「作業はそのリポのセッションで行う」から呼ぶ。手で叩いてもよい）
#
# 使い方: herdr-open-session.sh <リポのディレクトリ> <依頼を書いたファイル>
#
# 次を順に行う。
#   1. リポ名（worktree なら主チェックアウトの名前）から、使われていないセッション名 <リポ名>-<N> を決める
#      開いているペインの名前と、引き継ぎファイル（handoff-<リポ名>-<N>.md）が残っている番号は使わない
#      （閉じたセッションの引き継ぎを、新しいセッションが上書きしないため）
#   2. 依頼を ~/.claude/session-requests/<セッション名>.md へ写す
#   3. ラベルがリポ名の workspace があれば、そのペインを分けて新しいペインを作る。無ければ workspace から作る
#   4. 作ったペインで claude を開き、依頼のファイルを読ませる。起動したところまで確かめて返る（依頼の終わりは待たない）
#
# 設計方針:
# - 送り込むのは、このスクリプトが作ったばかりのペインだけ。既にあるペイン（人や他のセッションが
#   使っているもの）には何も送らない。だから guard-outbound-comms.sh はこの起動を止めない
#   （既にあるペインへの送り込みと herdr-restart-sessions.sh は従来どおり承認が要る）
# - 依頼の本文はコマンド行に載せずファイルで渡す。pane run の文字列はシェルが解釈するので、
#   本文の引用符や改行で壊れないようにするため
# - 結果は 1 行の JSON で標準出力に返す。途中で止まったら理由を標準エラーに出して exit 1
#   （作ったペインと依頼は片付ける）。claude を起動したが起動を確かめられないときだけ exit 3
#   （ペインと依頼を残す。やり直すと同じ依頼が二重に走るので、呼び出し側はやり直さない）
# - macOS 標準 bash 3.2 互換で書く

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

START_TIMEOUT_MS=90000
REQ_DIR="${HOME}/.claude/session-requests"
# コマンド行に載せる語の形（シェルで解釈されるため、記号を絞る）
NAME_RE='^[A-Za-z0-9._-]+-[0-9]+$'
PATH_RE='^[A-Za-z0-9/._-]+$'

die() {
    echo "herdr-open-session: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] || { echo "usage: $(basename "$0") <repo_dir> <request_file>" >&2; exit 2; }
_dir="$1"
_req="$2"

[ -s "${_req}" ] || die "依頼のファイルが無いか空: ${_req}"
_top="$(git -C "${_dir}" rev-parse --show-toplevel 2>/dev/null)" || die "git リポではない: ${_dir}"
_common="$(git -C "${_top}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "git の共通ディレクトリを取れない: ${_top}"
_main="$(dirname "${_common}")"
_repo="$(basename "${_main}")"
_mem="${HOME}/.claude/projects/$(printf '%s' "${_main}" | sed 's/[^A-Za-z0-9]/-/g')/memory"
printf '%s' "${_top}" | grep -qE "${PATH_RE}" || die "ディレクトリのパスに使えない文字がある: ${_top}"

# 1. 使われていないセッション名を決める
#    herdr を読めないまま進むと開いている名前と重なるので、読めなければ止める
_agents="$(herdr agent list 2>/dev/null)" || die "herdr agent list を読めない"
printf '%s' "${_agents}" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || die "herdr agent list の形が違う"
# 名前は herdr-restart-sessions.sh と同じく、状態の印を落とした terminal_title_stripped で見る
_titles="$(printf '%s' "${_agents}" | jq -r '.result.agents[] | .terminal_title_stripped // empty')"
_n=1
while :; do
    _name="${_repo}-${_n}"
    if ! printf '%s\n' "${_titles}" | grep -qxF -- "${_name}" \
        && [ ! -e "${_mem}/handoff-${_name}.md" ] \
        && [ ! -e "${REQ_DIR}/${_name}.md" ]; then
        break
    fi
    _n=$((_n + 1))
    [ "${_n}" -gt 99 ] && die "空いているセッション名が見つからない: ${_repo}-1〜99"
done
printf '%s' "${_name}" | grep -qE "${NAME_RE}" || die "セッション名に使えない文字がある: ${_name}"

# 2. 依頼を写す
mkdir -p "${REQ_DIR}" || die "置き場を作れない: ${REQ_DIR}"
_dest="${REQ_DIR}/${_name}.md"
printf '%s' "${_dest}" | grep -qE "${PATH_RE}" || die "依頼の置き場のパスに使えない文字がある: ${_dest}"
# noclobber で書き、同時に走った別の起動と同じ名前を取り合ったら止める（ファイルの有無が名前の予約になる）
( set -C; cat -- "${_req}" > "${_dest}" ) 2>/dev/null || die "依頼を写せない（同じ名前を別の起動が取ったかもしれない）: ${_dest}"

# 3. ペインを作る（workspace が無ければ workspace から）
#    一覧を読めないまま進むと、あるはずの workspace を二重に作るので止める
_wslist="$(herdr workspace list 2>/dev/null)" || { rm -f "${_dest}"; die "herdr workspace list を読めない"; }
_ws="$(printf '%s' "${_wslist}" | jq -r --arg l "${_repo}" '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty')"
if [ -z "${_ws}" ]; then
    _out="$(herdr workspace create --cwd "${_top}" --label "${_repo}" --no-focus 2>&1)" \
        || { rm -f "${_dest}"; die "workspace を作れない: ${_out}"; }
    _ws="$(printf '%s' "${_out}" | jq -r '.result.workspace.workspace_id // empty')"
    _pane="$(printf '%s' "${_out}" | jq -r '.result.root_pane.pane_id // empty')"
    _created=workspace
else
    _base="$(herdr pane list --workspace "${_ws}" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')"
    [ -n "${_base}" ] || { rm -f "${_dest}"; die "workspace ${_ws} のペインを取れない"; }
    _out="$(herdr pane split "${_base}" --direction right --cwd "${_top}" --no-focus 2>&1)" \
        || { rm -f "${_dest}"; die "ペインを分けられない: ${_out}"; }
    _pane="$(printf '%s' "${_out}" | jq -r '.result.pane.pane_id // empty')"
    _created=pane
fi
if [ -z "${_pane}" ]; then
    rm -f "${_dest}"
    if [ "${_created}" = workspace ] && [ -n "${_ws}" ]; then
        herdr workspace close "${_ws}" >/dev/null 2>&1 || echo "herdr-open-session: 作った workspace ${_ws} を閉じられない" >&2
    fi
    die "作ったペインの ID を取れない: ${_out}"
fi

# 4. claude を開いて依頼を読ませる
#    モデルは settings.json に残った値を引き継がず、opus で開く（herdr-restart-sessions.sh と同じ）
_prompt="${_dest} に別のセッションから回した依頼がある。読んだらファイルを消し、書かれた依頼を進める"
if ! herdr pane run "${_pane}" "claude -n ${_name} --model opus --permission-mode auto '${_prompt}'" >/dev/null 2>&1; then
    # 何も起動していないので、作ったものを片付けてやり直せる状態に戻す
    if [ "${_created}" = workspace ]; then
        herdr workspace close "${_ws}" >/dev/null 2>&1 || echo "herdr-open-session: 作った workspace ${_ws} を閉じられない" >&2
    else
        herdr pane close "${_pane}" >/dev/null 2>&1 || echo "herdr-open-session: 作ったペイン ${_pane} を閉じられない" >&2
    fi
    rm -f "${_dest}"
    die "claude を起動できない（作ったペインと依頼は片付けた）"
fi
if ! herdr pane wait-output "${_pane}" --match 'auto mode' --timeout "${START_TIMEOUT_MS}" >/dev/null 2>&1; then
    # claude は起動していて依頼を読み始めているかもしれない。やり直すと同じ依頼が 2 つのセッションで走るので、
    # 他の失敗（exit 1）と分けて exit 3 で返し、ペインも依頼も消さない
    echo "herdr-open-session: claude の起動を確かめられない。やり直さず、ペイン ${_pane}（${_name}）を開いて確かめる。依頼は ${_dest}" >&2
    exit 3
fi

jq -cn --arg name "${_name}" --arg pane "${_pane}" --arg ws "${_ws}" --arg created "${_created}" \
    --arg cwd "${_top}" --arg request "${_dest}" \
    '{name: $name, pane_id: $pane, workspace_id: $ws, created: $created, cwd: $cwd, request: $request}'
