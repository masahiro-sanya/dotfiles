#!/bin/bash
# morning-prep: /morning スキルの非対話・機械部分を launchd で事前実行する
# （claude 本体更新 / plugin marketplace 更新 / light-skills pull）
#
# 設計方針:
# - 各ステップは独立。失敗してもログに残して次へ進む（朝一は完走優先）
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

mkdir -p "${HOME}/.claude"
log "=== morning-prep start ==="

# --- 1. Claude Code 本体の更新（claude update は非対話） ---
if command -v claude >/dev/null 2>&1; then
    if claude update >> "${LOG_FILE}" 2>&1; then
        log "claude update: OK ($(claude --version 2>/dev/null || echo unknown))"
    else
        log "claude update: FAILED (続行)"
    fi
else
    log "claude update: SKIP (claude が見つからない)"
fi

# --- 2. プラグイン marketplace の更新（名前省略で全 marketplace） ---
if command -v claude >/dev/null 2>&1; then
    if claude plugin marketplace update >> "${LOG_FILE}" 2>&1; then
        log "plugin marketplace update: OK"
    else
        log "plugin marketplace update: FAILED (続行)"
    fi
else
    log "plugin marketplace update: SKIP (claude が見つからない)"
fi

# --- 3. light-skills の pull（dirty なら skip） ---
LIGHT_SKILLS_DIR="${HOME}/src/palmu/light-skills"
if [ -e "${LIGHT_SKILLS_DIR}/.git" ]; then
    if [ -n "$(git -C "${LIGHT_SKILLS_DIR}" status --porcelain 2>/dev/null)" ]; then
        log "light-skills pull: SKIP (working tree が dirty)"
    elif git -C "${LIGHT_SKILLS_DIR}" pull --ff-only >> "${LOG_FILE}" 2>&1; then
        log "light-skills pull: OK"
    else
        log "light-skills pull: FAILED (続行)"
    fi
else
    log "light-skills pull: SKIP (git リポではない: ${LIGHT_SKILLS_DIR})"
fi

# --- 完了スタンプ（/morning が今日実行済みかの判定に使う） ---
date +%Y-%m-%d > "${STAMP_FILE}"
log "=== morning-prep done ==="
