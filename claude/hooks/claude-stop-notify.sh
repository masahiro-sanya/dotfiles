#!/usr/bin/env bash
# Claude Code Stop hook
# 通知センター + ターミナルベル(wezterm tab highlight) + タブタイトル絵文字

set -u

PROJECT="$(basename "${PWD:-$HOME}")"
PROJECT_ESCAPED="${PROJECT//\"/\\\"}"

# 1) Terminal bell -> wezterm が tab を urgent state にして点滅/色変化
printf '\a'

# 2) システム音を直接再生（osascript の通知設定に依存しないため確実）
/usr/bin/afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &

# 3) macOS 通知センター（バナー表示用、音は afplay 側に任せる）
/usr/bin/osascript -e "display notification \"$PROJECT_ESCAPED\" with title \"Claude Done\"" >/dev/null 2>&1 &

# 3) Tab title に絵文字バッジ (wezterm OSC 2)
printf '\033]2;✅ %s\007' "$PROJECT"

exit 0
