#!/bin/bash
input=$(cat)

# 必要フィールドを jq 1回でまとめて取り出す（プロセス起動 6回 → 1回）
IFS=$'\t' read -r MODEL PCT COST DURATION_MS ADDED REMOVED CURRENT_DIR <<EOF
$(printf '%s' "$input" | jq -r '[
  (.model.display_name // "Claude"),
  (.context_window.used_percentage // 0),
  (.cost.total_cost_usd // 0),
  (.cost.total_duration_ms // 0),
  (.cost.total_lines_added // 0),
  (.cost.total_lines_removed // 0),
  (.workspace.current_dir // "")
] | @tsv' 2>/dev/null)
EOF

MODEL=${MODEL:-Claude}
PCT=${PCT%%.*}
PCT=${PCT:-0}
COST=${COST:-0}
DURATION_MS=${DURATION_MS:-0}
ADDED=${ADDED:-0}
REMOVED=${REMOVED:-0}

# Progress bar (20 chars wide)
FILLED=$((PCT * 20 / 100))
[ "$FILLED" -gt 20 ] && FILLED=20
BAR=""
for i in {1..20}; do
  if [ "$i" -le "$FILLED" ]; then
    BAR="${BAR}█"
  else
    BAR="${BAR}░"
  fi
done

# Color based on usage
if [ "$PCT" -ge 85 ]; then
  COLOR="\033[31m"  # Red
elif [ "$PCT" -ge 60 ]; then
  COLOR="\033[33m"  # Yellow
else
  COLOR="\033[36m"  # Cyan
fi
RESET="\033[0m"

COST_FMT=$(printf '%.2f' "$COST")

# Duration (minutes)
MINS=$((DURATION_MS / 60000))
SECS=$(( (DURATION_MS % 60000) / 1000 ))

# Git repo / branch（セッションの作業ディレクトリ基準。statusline プロセスの cwd に依存しない）
[ -z "$CURRENT_DIR" ] && CURRENT_DIR="$PWD"
BRANCH=$(git -C "$CURRENT_DIR" branch --show-current 2>/dev/null)
TOPLEVEL=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null)
REPO=""
[ -n "$TOPLEVEL" ] && REPO=$(basename "$TOPLEVEL")

# Build output
OUT=""
OUT="${OUT}\033[1;35m${MODEL}${RESET}"
OUT="${OUT}  ${COLOR}${BAR} ${PCT}%${RESET}"
OUT="${OUT}  \033[32m\$${COST_FMT}${RESET}"
OUT="${OUT}  ⏱ ${MINS}m${SECS}s"
OUT="${OUT}  \033[32m+${ADDED}\033[0m/\033[31m-${REMOVED}${RESET}"

if [ -n "$REPO" ]; then
  OUT="${OUT}  \033[1;37m${REPO}${RESET}"
fi

if [ -n "$BRANCH" ]; then
  OUT="${OUT}  \033[34m⎇ ${BRANCH}${RESET}"
fi

printf '%b' "$OUT"
