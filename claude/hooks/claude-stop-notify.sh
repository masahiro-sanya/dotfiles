#!/usr/bin/env bash
# Claude Code Stop hook
# 通知センター + ターミナルベル(wezterm tab highlight) + タブタイトル絵文字

set -u

PROJECT="$(basename "${PWD:-$HOME}")"
PROJECT_ESCAPED="${PROJECT//\"/\\\"}"

# 1) Terminal bell -> wezterm が tab を urgent state にして点滅/色変化
printf '\a'

# 2) macOS 通知センター（Glass 音付き）
/usr/bin/osascript -e "display notification \"$PROJECT_ESCAPED\" with title \"Claude Done\" sound name \"Glass\"" >/dev/null 2>&1 &

# 3) Tab title に絵文字バッジ (wezterm OSC 2)
printf '\033]2;✅ %s\007' "$PROJECT"

exit 0
