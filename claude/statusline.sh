#!/bin/bash
input=$(cat)

# Model
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Context usage
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Progress bar (20 chars wide)
FILLED=$((PCT * 20 / 100))
[ "$FILLED" -gt 20 ] && FILLED=20
BAR=""
for i in $(seq 1 20); do
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

# Cost
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
COST_FMT=$(printf '%.2f' "$COST")

# Duration (minutes)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
MINS=$((DURATION_MS / 60000))
SECS=$(( (DURATION_MS % 60000) / 1000 ))

# Lines changed
ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Git branch (cached to avoid slowness)
BRANCH=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
fi

# Build output
OUT=""
OUT="${OUT}\033[1;35m${MODEL}${RESET}"
OUT="${OUT}  ${COLOR}${BAR} ${PCT}%${RESET}"
OUT="${OUT}  \033[32m\$${COST_FMT}${RESET}"
OUT="${OUT}  ⏱ ${MINS}m${SECS}s"
OUT="${OUT}  \033[32m+${ADDED}\033[0m/\033[31m-${REMOVED}${RESET}"

if [ -n "$BRANCH" ]; then
  OUT="${OUT}  \033[34m⎇ ${BRANCH}${RESET}"
fi

printf '%b' "$OUT"
