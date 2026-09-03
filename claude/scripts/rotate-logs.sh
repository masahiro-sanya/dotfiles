#!/bin/bash
# rotate-logs.sh — ~/.claude 配下の追記専用ログにサイズ上限を掛ける。
#
# 対象は「日付で分かれず無限に伸びるログ」だけ。上限を超えたら 1 世代だけ
# <name>.1 へ退避して本体を空にするので、ディスク使用量は 2 × 上限で頭打ちになる。
#
# ~/.claude/logs/traces/ は対象にしない。日付ごとにファイルが分かれており、
# かつ「30 日ログの不在で未使用と断定しない」判定のために長く残すほど価値が上がる
# （2026-09-02 の監査でも削らない判断をしている）。
#
# 上限の決め方: guard-hits.log は全期間集計に使うので大きめ（実測 2 ヶ月で 361KB
# ＝ 年 2MB 程度なので、5MB なら実質ローテートせずに上限だけ効く）。
# 他は運用ログなので直近が読めれば足りる。
#
# 使い方: bash ~/.claude/scripts/rotate-logs.sh [--dry-run]
# morning-prep.sh（launchd で毎朝）から呼ばれる。
# macOS 標準 bash 3.2 互換で書く。

set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

CLAUDE_DIR="${CLAUDE_LOG_ROTATE_DIR:-${HOME}/.claude}"

# "<相対パス>:<上限バイト>" の並び（bash 3.2 に連想配列が無いため）
TARGETS="
guard-hits.log:5242880
morning-prep.log:2097152
collect-feed-prep.log:2097152
wezterm-status-error.log:1048576
hooks-error.log:1048576
"

file_size() {
    # BSD stat（macOS）。GNU stat のマシンでも動くようフォールバックする。
    # GNU stat は -f を --file-system と解釈して別物を exit 0 で返すため、
    # 終了コードでは切り替わらない。数字が返ったかで判定する。
    _s="$(stat -f %z "$1" 2>/dev/null || true)"
    case "${_s}" in
        ''|*[!0-9]*) _s="$(stat -c %s "$1" 2>/dev/null || true)" ;;
    esac
    case "${_s}" in
        ''|*[!0-9]*) _s=0 ;;
    esac
    echo "${_s}"
}

rotated=0
for entry in ${TARGETS}; do
    name="${entry%%:*}"
    limit="${entry##*:}"
    path="${CLAUDE_DIR}/${name}"

    [ -f "${path}" ] || continue

    size="$(file_size "${path}")"
    [ "${size}" -gt "${limit}" ] 2>/dev/null || continue

    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "would rotate: ${path} (${size} > ${limit})"
        rotated=$((rotated + 1))
        continue
    fi

    # mv ではなく cp + truncate にする。ログを開いたまま追記しているプロセス
    # （hook は毎回開き直すが、launchd 実行中の追記は開きっぱなし）が inode を
    # 掴んでいても、本体のパスと inode を保ったまま中身だけ空にできる。
    if cp -f "${path}" "${path}.1" 2>/dev/null; then
        : > "${path}"
        echo "rotated: ${path} (${size} bytes -> ${path}.1)"
        rotated=$((rotated + 1))
    else
        echo "rotate failed (続行): ${path}" >&2
    fi
done

[ "${rotated}" -eq 0 ] && echo "rotate-logs: 上限超過なし"
exit 0
