#!/bin/bash
# morning-prep: /morning スキルの非対話・機械部分を launchd で事前実行する
# （claude 本体更新 / plugin marketplace 更新 / 登録マーケットプレイスのプラグイン更新 / 登録リポの pull）
#
# 設計方針:
# - 各ステップは独立。失敗してもログに残して次へ進む（朝一は完走優先）
# - 外部に繋ぐステップは打ち切り時間を持つ（marketplace update が 20 分超止まった実例あり）
# - 失敗・打ち切り・pull 停止は最後に 1 回だけ通知する（ログだけだと誰も気づかない）
# - ログは ~/.claude/morning-prep.log に追記
# - 完了したら ~/.claude/.morning-prep-last に日付を書き、/morning 側が skip 判定に使う
# - macOS 標準 bash 3.2 互換で書く

set -u

LOG_FILE="${HOME}/.claude/morning-prep.log"
STAMP_FILE="${HOME}/.claude/.morning-prep-last"

# launchd から起動されると brew / claude が PATH に無いため明示的に通す
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}"
}

# 打ち切り時間（秒）
STEP_TIMEOUT=600

# 通知に載せる問題の一覧（改行区切りでなく "; " 区切りで 1 行にまとめる）
PROBLEMS=""
add_problem() {
    if [ -z "${PROBLEMS}" ]; then
        PROBLEMS="$1"
    else
        PROBLEMS="${PROBLEMS}; $1"
    fi
}

# 打ち切り処理（run_with_timeout）は 他のスクリプトと共通の lib-timeout.sh に置く。
# 打ち切ると kill -9 で終わるので rc は 137 になる
# ~/.claude/scripts/ の symlink 経由で起動されても dotfiles 側の実体の隣を見る
SCRIPT_DIR="$(dirname "$(/usr/bin/perl -MCwd -e 'print Cwd::abs_path(shift)' "$0")")"
# shellcheck source=lib-timeout.sh
. "${SCRIPT_DIR}/lib-timeout.sh" || {
    # 読めないまま進むと全ステップが rc=127 で「失敗」と誤って報告されるので、原因を書いて止める
    log "lib-timeout.sh を読めない（${SCRIPT_DIR}）。中止"
    osascript -e "display notification \"lib-timeout.sh を読めず中止\" with title \"morning-prep\"" >/dev/null 2>&1 || true
    exit 1
}

# 失敗理由の表示。rc=137 は run_with_timeout の打ち切り（kill -9）なので失敗と分けて書く
describe_rc() {
    if [ "$1" -eq 137 ]; then
        printf '%s' "打ち切り(${STEP_TIMEOUT}秒)"
    else
        printf '%s' "失敗(rc=$1)"
    fi
}

# 手順 1・2（/morning が skip 判定に使う部分）が 1 つでも失敗したら 1
PREP_FAILED=0

# LaunchAgent はユーザーの GUI セッションで走るので osascript が届く
notify_problems() {
    osascript -e "display notification \"$1\" with title \"morning-prep\"" >/dev/null 2>&1 || true
}

mkdir -p "${HOME}/.claude"
log "=== morning-prep start ==="

# --- 0. 追記専用ログのローテーション（上限超過分だけ 1 世代退避して空にする） ---
# 自分のログを膨らませる前に回す。traces は対象外（日付で分かれており長期保存に価値がある）。
ROTATE="${SCRIPT_DIR}/rotate-logs.sh"
if [ -f "${ROTATE}" ]; then
    log "rotate-logs: $(bash "${ROTATE}" 2>&1 | tr '\n' ' ')"
else
    log "rotate-logs: SKIP (見つからない: ${ROTATE})"
fi

# --- 1. Claude Code 本体の更新（claude update は非対話） ---
if command -v claude >/dev/null 2>&1; then
    run_with_timeout "${STEP_TIMEOUT}" claude update >> "${LOG_FILE}" 2>&1
    rc=$?
    if [ ${rc} -eq 0 ]; then
        log "claude update: OK ($(claude --version 2>/dev/null || echo unknown))"
    else
        log "claude update: FAILED $(describe_rc ${rc}) (続行)"
        add_problem "claude update $(describe_rc ${rc})"
        PREP_FAILED=1
    fi
else
    log "claude update: SKIP (claude が見つからない)"
fi

# --- 2. プラグイン marketplace の更新（名前省略で全 marketplace） ---
if command -v claude >/dev/null 2>&1; then
    run_with_timeout "${STEP_TIMEOUT}" claude plugin marketplace update >> "${LOG_FILE}" 2>&1
    rc=$?
    if [ ${rc} -eq 0 ]; then
        log "plugin marketplace update: OK"
    else
        log "plugin marketplace update: FAILED $(describe_rc ${rc}) (続行)"
        add_problem "marketplace update $(describe_rc ${rc})"
        PREP_FAILED=1
    fi
else
    log "plugin marketplace update: SKIP (claude が見つからない)"
fi

# --- 2b. 登録マーケットプレイスのプラグイン本体の更新 ---
# marketplace update は一覧を新しくするだけで、入っているプラグインは古い版のまま残る
# （朝の定時実行が更新前の版で走る）。user スコープのものを 1 件ずつ更新する。
# 対象は ~/.claude/private/morning-prep-marketplaces.txt（git 管理外・1 行 1 マーケットプレイス名・'#' 以降は注釈）。
# ファイルが無ければ何もしない（/morning の手順 2 が更新する）。テスト用に MORNING_PREP_MARKETPLACES_FILE で差し替え可。
# -y / --accept-command は渡さない。マーケットプレイスが宣言したコマンドの確認を求められたら
# 無人で承認せずスキップし、/morning の手順 2（人が見る）で更新させる
MARKETPLACES_FILE="${MORNING_PREP_MARKETPLACES_FILE:-${HOME}/.claude/private/morning-prep-marketplaces.txt}"
PLUGINS_FILE="${HOME}/.claude/plugins/installed_plugins.json"
if [ ! -f "${MARKETPLACES_FILE}" ]; then
    :
elif [ "${PREP_FAILED}" -ne 0 ]; then
    # 打ち切り・失敗の直後に 1 件 600 秒 × 全件を回すと何時間も居座るので、/morning の手順 2 に任せる
    log "plugin update: SKIP (手順 1・2 が失敗したので /morning の手順 2 で更新させる)"
elif ! command -v claude >/dev/null 2>&1; then
    log "plugin update: SKIP (claude が見つからない)"
elif ! command -v jq >/dev/null 2>&1; then
    log "plugin update: SKIP (jq が見つからない)"
    add_problem "plugin update が jq 不在で未実行"
elif [ ! -r "${PLUGINS_FILE}" ]; then
    log "plugin update: SKIP (${PLUGINS_FILE} を読めない)"
    add_problem "plugin update が installed_plugins.json を読めず未実行"
else
    plugin_aborted=0
    while IFS= read -r market || [ -n "${market}" ]; do
        market="$(printf '%s' "${market}" | sed 's/#.*//' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${market}" ] && continue
        if ! plugin_list="$(jq -r --arg m "@${market}" '.plugins | to_entries[] | select((.key | endswith($m)) and any(.value[]; .scope == "user")) | .key' "${PLUGINS_FILE}" 2>> "${LOG_FILE}")"; then
            log "plugin update ${market}: SKIP (${PLUGINS_FILE} を解釈できない)"
            add_problem "plugin update ${market} が installed_plugins.json を解釈できず未実行"
            continue
        fi
        plugin_ok=0
        plugin_ng=""
        while IFS= read -r plugin; do
            [ -z "${plugin}" ] && continue
            if [ "${plugin_aborted}" -ne 0 ]; then
                plugin_ng="${plugin_ng} ${plugin%@"${market}"}(打ち切り後で未実行)"
                continue
            fi
            # stdin を塞いで確認プロンプトで止まらないようにする（非 TTY では -y 無しの確認は拒否される）
            out="$(run_with_timeout "${STEP_TIMEOUT}" claude plugin update "${plugin}" -s user --json < /dev/null 2>&1)"
            rc=$?
            log "plugin update ${plugin}: rc=${rc} ${out}"
            if printf '%s' "${out}" | grep -q 'shownCommand'; then
                log "plugin update ${plugin}: SKIP (マーケットプレイス宣言のコマンドに確認が要る)"
                plugin_ng="${plugin_ng} ${plugin%@"${market}"}(要確認)"
            elif [ ${rc} -eq 0 ]; then
                plugin_ok=$((plugin_ok + 1))
            else
                log "plugin update ${plugin}: FAILED $(describe_rc ${rc}) (続行)"
                plugin_ng="${plugin_ng} ${plugin%@"${market}"}($(describe_rc ${rc}))"
                # 1 件打ち切られたらネットワークが詰まっている。残りも 600 秒ずつ待つと何時間も居座るので止める
                [ ${rc} -eq 137 ] && plugin_aborted=1
            fi
        done <<< "${plugin_list}"
        if [ "${plugin_ok}" -eq 0 ] && [ -z "${plugin_ng}" ]; then
            # 対象 0 件は名前の書き間違いか、jq の絞り込みが installed_plugins.json の形と合わなくなった疑い
            log "plugin update ${market}: 対象 0 件（morning-prep-marketplaces.txt と ${PLUGINS_FILE} の形を確認）"
            add_problem "plugin update ${market} の対象が 0 件"
        elif [ -n "${plugin_ng}" ]; then
            log "plugin update ${market}: OK ${plugin_ok} 件、未更新:${plugin_ng}"
            add_problem "plugin update ${market} 未更新:${plugin_ng}"
        else
            log "plugin update ${market}: OK ${plugin_ok} 件"
        fi
    done < "${MARKETPLACES_FILE}"
fi

# --- 3. 登録リポの pull（dirty なら skip） ---
# 対象は ~/.claude/private/morning-prep-repos.txt（git 管理外・1 行 1 パス・~ 始まり可・'#' 以降は注釈）。
# ファイルが無ければ何もしない。テスト用に MORNING_PREP_REPOS_FILE で差し替え可
REPOS_FILE="${MORNING_PREP_REPOS_FILE:-${HOME}/.claude/private/morning-prep-repos.txt}"
pull_repo() {
    local repo_dir="$1"
    local name
    name="$(basename "${repo_dir}")"
    if [ -e "${repo_dir}/.git" ]; then
        if [ -n "$(git -C "${repo_dir}" status --porcelain 2>/dev/null)" ]; then
            log "${name} pull: SKIP (working tree が dirty)"
            add_problem "${name} が未コミット変更ありで pull 停止中"
        else
            # 認証プロンプトで止まらないよう GIT_TERMINAL_PROMPT=0、ネットワーク待ちは打ち切り時間で切る
            GIT_TERMINAL_PROMPT=0 run_with_timeout "${STEP_TIMEOUT}" git -C "${repo_dir}" pull --ff-only < /dev/null >> "${LOG_FILE}" 2>&1
            rc=$?
            if [ ${rc} -eq 0 ]; then
                log "${name} pull: OK"
            else
                # 打ち切り（kill -9）は git が index.lock を消す暇を与えない。残すと翌日以降の pull も
                # "index.lock exists" で失敗し続けるので、自分で殺した分だけここで片付ける
                if [ ${rc} -eq 137 ]; then
                    lock="$(git -C "${repo_dir}" rev-parse --absolute-git-dir 2>/dev/null)/index.lock"
                    if [ -f "${lock}" ]; then
                        rm -f "${lock}" && log "${name} pull: 打ち切りで残った index.lock を削除"
                    fi
                fi
                log "${name} pull: FAILED $(describe_rc ${rc}) (続行)"
                add_problem "${name} pull $(describe_rc ${rc})"
            fi
        fi
    else
        # 登録したのに git リポでない＝パスの書き間違い・移動。ログだけだと気づかないので通知にも載せる
        log "${name} pull: SKIP (git リポではない: ${repo_dir})"
        add_problem "${name} が git リポではないため pull 対象外（morning-prep-repos.txt を確認）"
    fi
}
if [ -f "${REPOS_FILE}" ]; then
    while IFS= read -r repo_line || [ -n "${repo_line}" ]; do
        repo_line="$(printf '%s' "${repo_line}" | sed 's/#.*//' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${repo_line}" ] && continue
        case "${repo_line}" in
            \~|\~/*) repo_line="${HOME}${repo_line#\~}" ;;
        esac
        pull_repo "${repo_line}"
    done < "${REPOS_FILE}"
fi

# --- 完了スタンプ（/morning が今日実行済みかの判定に使う） ---
# 手順 1・2 が失敗・打ち切りのときは書かない（書くと /morning が当日の再実行を skip してしまう）
if [ "${PREP_FAILED}" -eq 0 ]; then
    date +%Y-%m-%d >| "${STAMP_FILE}"
else
    log "stamp: SKIP (手順 1・2 が失敗したので /morning 側で再実行させる)"
fi
if [ -n "${PROBLEMS}" ]; then
    log "problems: ${PROBLEMS}"
    notify_problems "${PROBLEMS}（詳細は ~/.claude/morning-prep.log）"
fi
log "=== morning-prep done ==="
