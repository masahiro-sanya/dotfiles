#!/bin/bash
# herdr-restart-sessions: herdr の Claude セッションを、引き継ぎを書かせてから開き直す（または閉じる）
# （/morning の「他セッションの開き直し」から呼ぶ。手で叩いてもよい）
#
# 使い方: herdr-restart-sessions.sh [--close] <pane_id> [[--close] <pane_id>]...
#   --close を前に付けたペインは、開き直さずに閉じる
#
# ペインごとに次を順に行う。
#   1. /handoff 書く を送り、引き継ぎファイル（<リポの memory>/handoff-<セッション名>.md）が書き直されるのを待つ
#   2. /exit を送り、ペインに claude のプロセスが残っていないことを確かめる
#      （バックグラウンドの処理が残っていて確認画面が出たら、Esc で閉じて止める）
#   3. 同じセッション名で claude を開き直し、/handoff 読むだけ で引き継ぎを読ませる
#      --close のペインは開き直さずにペインを閉じ、ワークスペースが空になればそれも閉じる
#      （開き直しただけで使われないセッションが、1 本あたり MCP サーバー込みで 1GB 近く使い続けるため）
#
# 設計方針:
# - 他のペインへ入力を送り込むので、guard-outbound-comms.sh はこのスクリプトの起動自体を
#   herdr の送信として止める。outbound-ok 1 回で 1 回の一括実行を通す形にするためで、
#   ガードから送信を隠すためのものではない（中で叩く herdr はガードの外で走る）。
#   /morning 手順 10 から呼ぶときは、ユーザーが打った /morning の起動を承認とみなして
#   確認なしでマーカーを作る（claude/CLAUDE.md の例外。バイパスは guard-hits.log に残る）
# - 途中で詰まったペインはそこで止めて次のペインへ進む。止めたペインは開き直さない
#   （引き継ぎを書けていないセッションを閉じると、作業の続きが消える）
# - 同じリポのセッションは 1 つずつ、別のリポは並べて流す。同じ memory の MEMORY.md を
#   同時に書き換えさせないため
# - 自分自身のペイン（HERDR_PANE_ID）は対象にしない
# - macOS 標準 bash 3.2 互換で書く

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

# 待ち時間（ミリ秒）
HANDOFF_TIMEOUT_MS=900000
START_TIMEOUT_MS=90000
READ_TIMEOUT_MS=600000

# 抜けたあと claude のプロセスが消えるまで待つ回数（2 秒ごと）
EXIT_POLLS=30

usage() {
    echo "usage: $(basename "$0") [--close] <pane_id> [[--close] <pane_id>]..." >&2
    exit 2
}
[ "$#" -eq 0 ] && usage
# --close の後ろにペインが無い・知らないオプションがあれば、何も送らずに止める
_after_close=0
for _arg in "$@"; do
    case "${_arg}" in
        --close)
            [ "${_after_close}" -eq 1 ] && usage
            _after_close=1
            ;;
        -*) usage ;;
        *) _after_close=0 ;;
    esac
done
[ "${_after_close}" -eq 1 ] && usage

# セッション名として通す形（claude -n にそのまま渡してシェルで解釈されるため、記号を絞る）
NAME_RE='^[A-Za-z0-9._-]+-[0-9]+$'

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
# 止められたら、並べて走らせている流れも止める（親だけ抜けて子が送り続けないように）
trap 'kill $(jobs -p) 2>/dev/null; exit 130' INT TERM

# 1 ペイン分の結果を 1 行で残す。最後にまとめて出す
result() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${WORK_DIR}/results"
}

# "<agent>\x1f<状態>\x1f<名前>\x1f<cwd>\x1f<ワークスペース>" を 1 回の herdr 呼び出しで返す。取れなければ空。
# 区切りをタブにしないのは、read が空の欄を詰めて欄がずれるため
pane_info() {
    herdr pane get "$1" 2>/dev/null \
        | jq -r '.result.pane // empty | [.agent // "", .agent_status // "", .terminal_title_stripped // "", .cwd // "", .workspace_id // ""] | join("\u001f")'
}

# ペインの前面に claude 以外（シェル）しか残っていなければ 0
only_shell_left() {
    herdr pane process-info --pane "$1" 2>/dev/null \
        | jq -e '[.result.process_info.foreground_processes[] | select((.name // "") | test("^-?(zsh|bash|sh)$") | not)] | length == 0' >/dev/null
}

# /exit がバックグラウンドの処理を止めてよいかを聞く画面を出していれば 0、出ていなければ 1、
# 画面を読めなければ 2。確認画面は画面の下端に出るので、会話の本文と取り違えないよう下の数行だけ見る
BG_DIALOG_LINES=15
bg_dialog_shown() {
    local _screen
    _screen="$(herdr pane read "$1" --source visible 2>/dev/null)" || return 2
    # 確認画面の下は空行で埋まるので、末尾の空行を落としてから下の行を取る
    _screen="$(printf '%s\n' "${_screen}" | awk -v n="${BG_DIALOG_LINES}" '
        { l[NR] = $0 } NF { last = NR }
        END { s = last - n + 1; if (s < 1) s = 1; for (i = s; i <= last; i++) print l[i] }')"
    printf '%s\n' "${_screen}" | grep -qF 'Background work is running' \
        && printf '%s\n' "${_screen}" | grep -qF 'Exit and stop tasks'
}

# "<状態>\t<完了番号>" を返す。完了番号はターンが終わるたびに変わる
agent_state() {
    herdr agent get "$1" 2>/dev/null \
        | jq -r '.result.agent | "\(.agent_status // "")\t\(.completion_seq // "")"'
}

# 送った入力でエージェントが動き出し、手が空くまで待つ。
# 送った直後は idle のままなので、working を見るか、完了番号が送る前（$2）から変わるまで待つ。
# herdr agent wait は長く待つと idle への変化を取りこぼして返らなかったので、自分で 2 秒ごとに見る
wait_turn() {
    local _pane _before _limit _elapsed _seen _state _status _seq
    _pane="$1"
    _before="$2"
    _limit=$(($3 / 1000))
    _elapsed=0
    _seen=0
    while [ "${_elapsed}" -lt "${_limit}" ]; do
        # read の IFS にタブを使うと、空の状態が詰められて完了番号が状態の側に入るので cut で分ける
        _state="$(agent_state "${_pane}")"
        _status="$(printf '%s\n' "${_state}" | cut -f1)"
        _seq="$(printf '%s\n' "${_state}" | cut -f2)"
        case "${_status}" in
            working) _seen=1 ;;
            idle|blocked)
                # 送る前の完了番号が取れていないとき（空）は、番号の変化では判定しない。
                # 空との比較だと、まだ動き出していない idle を「終わった」と取り違える
                if [ "${_seen}" -eq 1 ] || { [ -n "${_before}" ] && [ -n "${_seq}" ] && [ "${_seq}" != "${_before}" ]; }; then
                    printf '%s\n' "${_status}"
                    return
                fi
                ;;
        esac
        sleep 2
        _elapsed=$((_elapsed + 2))
    done
    printf 'timeout\n'
}

memory_dir() {
    local _common
    _common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    printf '%s/.claude/projects/%s/memory\n' "${HOME}" "$(dirname "${_common}" | sed 's/[^A-Za-z0-9]/-/g')"
}

# 開き直さないペインを閉じる。claude はもう抜けているので引き継ぎは残るが、ペインを閉じられなければ
# シェルだけのペインが claude の表示のまま残るので「要確認」にする（「閉じた」に数えると exit 0 で見逃す）
close_pane() {
    local _pane _name _ws _panes
    _pane="$1"
    _name="$2"
    _ws="$3"
    if ! herdr pane close "${_pane}" >/dev/null 2>&1; then
        result "${_pane}" "${_name}" "要確認: 引き継ぎを書いて claude は終了したが、ペインを閉じられずシェルが残っている"
        return
    fi
    if [ -z "${_ws}" ]; then
        result "${_pane}" "${_name}" "閉じた: 引き継ぎを書いて終了"
        return
    fi
    # ほかのペインが残るワークスペースは閉じない。herdr は失敗も JSON（.error）で stdout に返すので、
    # .result.panes が配列で取れたときだけ数える（取れなければ触らない）
    _panes="$(herdr pane list --workspace "${_ws}" 2>/dev/null \
        | jq -r 'if (.result.panes | type) == "array" then (.result.panes | length) else empty end' 2>/dev/null)"
    if [ -z "${_panes}" ]; then
        result "${_pane}" "${_name}" "閉じた: 引き継ぎを書いて終了（ワークスペース ${_ws} は一覧を読めないので閉じていない）"
        return
    fi
    if [ "${_panes}" != "0" ]; then
        result "${_pane}" "${_name}" "閉じた: 引き継ぎを書いて終了（ワークスペース ${_ws} はほかのペインが残るので閉じていない）"
        return
    fi
    if ! herdr workspace close "${_ws}" >/dev/null 2>&1; then
        result "${_pane}" "${_name}" "閉じた: 引き継ぎを書いて終了（空のワークスペース ${_ws} は閉じられなかった）"
        return
    fi
    result "${_pane}" "${_name}" "閉じた: 引き継ぎを書いて終了（空になったワークスペース ${_ws} も閉じた）"
}

restart_pane() {
    local _pane _name _mem _mode _ws _seq0 _file _stamp _state _status _before
    _pane="$1"
    _name="$2"
    _mem="$3"
    _mode="$4"
    _ws="$5"
    _seq0="$6"
    _file="${_mem}/handoff-${_name}.md"
    _stamp="${WORK_DIR}/stamp-${_name}"
    touch "${_stamp}"

    # 0. 送る直前に idle を確かめ直す。同じリポの後ろのペインは前のペインが終わるまで
    #    （最大十数分）待つので、最初に見た idle のあいだに人が作業を始めていることがある
    _state="$(agent_state "${_pane}")"
    _status="$(printf '%s\n' "${_state}" | cut -f1)"
    if [ "${_status}" != "idle" ]; then
        result "${_pane}" "${_name}" "対象外: 送る直前に ${_status:-状態を取れない}（作業中に割り込まない）"
        return
    fi
    # 前の実行が /exit のあとで止まった・ペインを閉じられなかったペインは、claude の表示のまま
    # シェルだけが残っている。ここへ /handoff を送るとシェルのコマンドになるので送らない
    if only_shell_left "${_pane}"; then
        result "${_pane}" "${_name}" "要確認: claude が動いていない（シェルだけのペイン。開き直すか閉じるかをペインで決める）"
        return
    fi
    # 閉じる判定のあとで使われた（完了番号が対象を確かめたときから変わった）ペインは、閉じずに開き直す
    _before="$(printf '%s\n' "${_state}" | cut -f2)"
    if [ "${_mode}" = "close" ] && [ -n "${_seq0}" ] && [ -n "${_before}" ] && [ "${_before}" != "${_seq0}" ]; then
        _mode=reopen
    fi

    # 1. 引き継ぎを書かせる。引数なしだと、会話の最初の発話のときに「読む」で動くので「書く」を付ける
    if ! herdr agent prompt "${_pane}" "/handoff 書く" >/dev/null 2>&1; then
        result "${_pane}" "${_name}" "停止: /handoff を送れなかった"
        return
    fi
    _status="$(wait_turn "${_pane}" "${_before}" "${HANDOFF_TIMEOUT_MS}")"
    if [ "${_status}" != "idle" ]; then
        result "${_pane}" "${_name}" "停止: /handoff のあと ${_status}（ペインを開いて確かめる）"
        return
    fi
    if [ ! -f "${_file}" ] || [ ! "${_file}" -nt "${_stamp}" ]; then
        result "${_pane}" "${_name}" "停止: ${_file} が書き直されていない"
        return
    fi

    # 2. 抜ける。herdr の表示は抜けたあとも claude のまま残るので、プロセスで確かめる
    if ! herdr agent prompt "${_pane}" "/exit" >/dev/null 2>&1; then
        result "${_pane}" "${_name}" "停止: /exit を送れなかった（引き継ぎは書けている）"
        return
    fi
    local _i _dialog _read_failed
    _i=0
    _read_failed=0
    while ! only_shell_left "${_pane}"; do
        _i=$((_i + 1))
        # バックグラウンドの処理が残っていると、/exit は止めてよいかを聞く画面で待つ。
        # 止めるかどうかは人が決めるので選ばずに Esc で閉じ、セッションをそのまま残す。
        # 会話の本文に同じ文言があっても普通に抜ける間は拾わないよう、2 回目の確認から見る
        if [ "${_i}" -ge 2 ]; then
            bg_dialog_shown "${_pane}"
            _dialog=$?
            [ "${_dialog}" -eq 2 ] && _read_failed=1
        else
            _dialog=1
        fi
        if [ "${_dialog}" -eq 0 ]; then
            if ! herdr agent send-keys "${_pane}" esc >/dev/null 2>&1; then
                result "${_pane}" "${_name}" "停止: バックグラウンドの処理が残っていて、確認画面を Esc で閉じられなかった（ペインを開いて選ぶ）"
                return
            fi
            # 読んだあとで人が選んで抜けていたら、Esc はシェルに入っている。残ったと報告しない
            sleep 1
            if only_shell_left "${_pane}"; then
                result "${_pane}" "${_name}" "要確認: 確認画面を閉じる前に claude が抜けていた（開き直していない。引き継ぎは書けている）"
            else
                result "${_pane}" "${_name}" "停止: バックグラウンドの処理が残っている（止めるかはペインで決める。引き継ぎは書けている）"
            fi
            return
        fi
        if [ "${_i}" -ge "${EXIT_POLLS}" ]; then
            if [ "${_read_failed}" -eq 1 ]; then
                result "${_pane}" "${_name}" "停止: /exit のあとも claude が残っている（画面を読めず、確認画面か確かめられない）"
            else
                result "${_pane}" "${_name}" "停止: /exit のあとも claude が残っている"
            fi
            return
        fi
        sleep 2
    done

    if [ "${_mode}" = "close" ]; then
        close_pane "${_pane}" "${_name}" "${_ws}"
        return
    fi

    # 3. 同じ名前で開き直し、引き継ぎを読ませる（読んだところで止まる）。
    #    ここから先で確かめられなかったものは、前の claude はもう閉じているので「要確認」にする
    #    （「開き直した」に数えない）
    if ! herdr pane run "${_pane}" "claude -n ${_name} --permission-mode auto '/handoff 読むだけ'" >/dev/null 2>&1; then
        result "${_pane}" "${_name}" "要確認: claude を起動できなかった（閉じたままのペイン）"
        return
    fi
    if ! herdr pane wait-output "${_pane}" --match 'auto mode' --timeout "${START_TIMEOUT_MS}" >/dev/null 2>&1; then
        result "${_pane}" "${_name}" "要確認: claude の起動を確かめられない（ペインを開いて確かめる）"
        return
    fi
    # 完了番号は、起動したあとの新しいセッションの値を基準にする（閉じる前の値は表示が残っているだけ）
    _before="$(agent_state "${_pane}" | cut -f2)"
    _status="$(wait_turn "${_pane}" "${_before}" "${READ_TIMEOUT_MS}")"
    if [ "${_status}" != "idle" ]; then
        result "${_pane}" "${_name}" "要確認: 開き直したが読み込みのあと ${_status}（ペインを開いて確かめる）"
        return
    fi
    result "${_pane}" "${_name}" "開き直した: 引き継ぎを読んで待機中"
}

# 対象を確かめ、"<memory>\t<pane>\t<name>\t<reopen|close>\t<ワークスペース>\t<完了番号>" の行にする
: > "${WORK_DIR}/targets"
_next_mode=reopen
for pane in "$@"; do
    if [ "${pane}" = "--close" ]; then
        _next_mode=close
        continue
    fi
    mode="${_next_mode}"
    _next_mode=reopen
    if [ "${pane}" = "${HERDR_PANE_ID:-}" ]; then
        result "${pane}" "-" "対象外: 自分のペイン"
        continue
    fi
    if cut -f2 "${WORK_DIR}/targets" | grep -qxF -- "${pane}"; then
        result "${pane}" "-" "対象外: 重複して指定された"
        continue
    fi
    info="$(pane_info "${pane}")"
    if [ -z "${info}" ]; then
        result "${pane}" "-" "対象外: herdr pane get で状態を取れない"
        continue
    fi
    IFS="$(printf '\037')" read -r agent status name cwd ws <<EOF
${info}
EOF
    if [ "${agent}" != "claude" ]; then
        result "${pane}" "${name:--}" "対象外: claude のペインではない（${agent:-なし}）"
        continue
    fi
    if [ "${status}" != "idle" ]; then
        result "${pane}" "${name:--}" "対象外: ${status}（作業中に割り込まない）"
        continue
    fi
    # 名前はそのまま claude -n に渡してシェルで解釈されるので、リポ名-番号の形だけ通す
    if ! [[ "${name}" =~ ${NAME_RE} ]]; then
        result "${pane}" "${name:--}" "対象外: セッション名がリポ名-番号の形ではない"
        continue
    fi
    if ! mem="$(memory_dir "${cwd}")"; then
        result "${pane}" "${name}" "対象外: git リポの外（${cwd}）"
        continue
    fi
    # 閉じるペインは、この時点の完了番号を控える（同じリポの流れを待つ間に使われたら閉じない）
    seq0=""
    [ "${mode}" = "close" ] && seq0="$(agent_state "${pane}" | cut -f2)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${mem}" "${pane}" "${name}" "${mode}" "${ws}" "${seq0}" >> "${WORK_DIR}/targets"
done

# リポ（memory）ごとに 1 本の流れにして、流れどうしは並べて走らせる。
# 流れはパイプの右側に置かない（パイプの中の while は別プロセスになり、止めたときに残る）
_n=0
cut -f1 "${WORK_DIR}/targets" | sort -u > "${WORK_DIR}/mems"
while IFS= read -r mem; do
    _n=$((_n + 1))
    awk -F'\t' -v m="${mem}" '$1 == m' "${WORK_DIR}/targets" > "${WORK_DIR}/queue-${_n}"
    (
        while IFS= read -r line; do
            # read の IFS にタブを使うと空の欄（ワークスペース・完了番号）が詰められて欄がずれるので cut で分ける
            pane="$(printf '%s\n' "${line}" | cut -f2)"
            name="$(printf '%s\n' "${line}" | cut -f3)"
            mode="$(printf '%s\n' "${line}" | cut -f4)"
            ws="$(printf '%s\n' "${line}" | cut -f5)"
            seq0="$(printf '%s\n' "${line}" | cut -f6)"
            # herdr に while の入力を食わせない
            restart_pane "${pane}" "${name}" "${mem}" "${mode}" "${ws}" "${seq0}" < /dev/null
        done < "${WORK_DIR}/queue-${_n}"
    ) &
done < "${WORK_DIR}/mems"
wait

sort "${WORK_DIR}/results" 2>/dev/null | awk -F'\t' '{ printf "%-8s %-24s %s\n", $1, $2, $3 }'

# 止めたペイン・確かめられなかったペイン・状態を読めなかったペインがあれば、呼び出し側が成功と取り違えないよう 1 で終える
if cut -f3 "${WORK_DIR}/results" 2>/dev/null | grep -qE '^(停止|要確認)|取れない'; then
    exit 1
fi
