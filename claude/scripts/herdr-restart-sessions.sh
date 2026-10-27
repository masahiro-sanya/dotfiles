#!/bin/bash
# herdr-restart-sessions: herdr の Claude セッションを、引き継ぎを書かせてから開き直す
# （/morning の「全セッションの開き直し」から呼ぶ。手で叩いてもよい）
#
# 使い方: herdr-restart-sessions.sh <pane_id>...
#
# ペインごとに次を順に行う。
#   1. /handoff 書く を送り、引き継ぎファイル（<リポの memory>/handoff-<セッション名>.md）が書き直されるのを待つ
#   2. /exit を送り、ペインに claude のプロセスが残っていないことを確かめる
#   3. 同じセッション名で claude を開き直し、/handoff 読むだけ で引き継ぎを読ませる
#
# 設計方針:
# - 他のペインへ入力を送り込むので、guard-outbound-comms.sh はこのスクリプトの起動自体を
#   herdr の送信として止める。承認 1 回で 1 回の一括実行を通す形にするためで、
#   ガードから送信を隠すためのものではない（中で叩く herdr はガードの外で走る）
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

if [ "$#" -eq 0 ]; then
    echo "usage: $(basename "$0") <pane_id>..." >&2
    exit 2
fi

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

# "<agent>\x1f<状態>\x1f<名前>\x1f<cwd>" を 1 回の herdr 呼び出しで返す。取れなければ空。
# 区切りをタブにしないのは、read が空の欄を詰めて欄がずれるため
pane_info() {
    herdr pane get "$1" 2>/dev/null \
        | jq -r '.result.pane // empty | [.agent // "", .agent_status // "", .terminal_title_stripped // "", .cwd // ""] | join("\u001f")'
}

# ペインの前面に claude 以外（シェル）しか残っていなければ 0
only_shell_left() {
    herdr pane process-info --pane "$1" 2>/dev/null \
        | jq -e '[.result.process_info.foreground_processes[] | select((.name // "") | test("^-?(zsh|bash|sh)$") | not)] | length == 0' >/dev/null
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

restart_pane() {
    local _pane _name _mem _file _stamp _state _status _before
    _pane="$1"
    _name="$2"
    _mem="$3"
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

    # 1. 引き継ぎを書かせる。引数なしだと、会話の最初の発話のときに「読む」で動くので「書く」を付ける
    _before="$(printf '%s\n' "${_state}" | cut -f2)"
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
    local _i
    _i=0
    while ! only_shell_left "${_pane}"; do
        _i=$((_i + 1))
        if [ "${_i}" -ge "${EXIT_POLLS}" ]; then
            result "${_pane}" "${_name}" "停止: /exit のあとも claude が残っている"
            return
        fi
        sleep 2
    done

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

# 対象を確かめ、"<memory>\t<pane>\t<name>\t<cwd>" の行にする
: > "${WORK_DIR}/targets"
for pane in "$@"; do
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
    IFS="$(printf '\037')" read -r agent status name cwd <<EOF
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
    printf '%s\t%s\t%s\n' "${mem}" "${pane}" "${name}" >> "${WORK_DIR}/targets"
done

# リポ（memory）ごとに 1 本の流れにして、流れどうしは並べて走らせる。
# 流れはパイプの右側に置かない（パイプの中の while は別プロセスになり、止めたときに残る）
_n=0
cut -f1 "${WORK_DIR}/targets" | sort -u > "${WORK_DIR}/mems"
while IFS= read -r mem; do
    _n=$((_n + 1))
    awk -F'\t' -v m="${mem}" '$1 == m' "${WORK_DIR}/targets" > "${WORK_DIR}/queue-${_n}"
    (
        while IFS="$(printf '\t')" read -r _ pane name; do
            # herdr に while の入力を食わせない
            restart_pane "${pane}" "${name}" "${mem}" < /dev/null
        done < "${WORK_DIR}/queue-${_n}"
    ) &
done < "${WORK_DIR}/mems"
wait

sort "${WORK_DIR}/results" 2>/dev/null | awk -F'\t' '{ printf "%-8s %-24s %s\n", $1, $2, $3 }'

# 止めたペイン・確かめられなかったペイン・状態を読めなかったペインがあれば、呼び出し側が成功と取り違えないよう 1 で終える
if cut -f3 "${WORK_DIR}/results" 2>/dev/null | grep -qE '^(停止|要確認)|取れない'; then
    exit 1
fi
