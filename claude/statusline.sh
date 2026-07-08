#!/bin/bash
input=$(cat)

# 必要フィールドを jq 1回でまとめて取り出す（プロセス起動 6回 → 1回）
IFS=$'\t' read -r MODEL PCT COST DURATION_MS ADDED REMOVED CURRENT_DIR RL5_PCT RL5_RESET RL7_PCT RL7_RESET <<EOF
$(printf '%s' "$input" | jq -r '[
  (.model.display_name // "Claude"),
  (.context_window.used_percentage // 0),
  (.cost.total_cost_usd // 0),
  (.cost.total_duration_ms // 0),
  (.cost.total_lines_added // 0),
  (.cost.total_lines_removed // 0),
  (.workspace.current_dir // ""),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at // "")
] | @tsv' 2>/dev/null)
EOF

MODEL=${MODEL:-Claude}
ADDED=${ADDED:-0}
REMOVED=${REMOVED:-0}

RESET="\033[0m"

# Git repo / branch（セッションの作業ディレクトリ基準。statusline プロセスの cwd に依存しない）
[ -z "$CURRENT_DIR" ] && CURRENT_DIR="$PWD"
BRANCH=$(git -C "$CURRENT_DIR" branch --show-current 2>/dev/null)
TOPLEVEL=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null)
REPO=""
[ -n "$TOPLEVEL" ] && REPO=$(basename "$TOPLEVEL")

# Build output
OUT=""
OUT="${OUT}\033[1;35m${MODEL}${RESET}"

if [ -n "$REPO" ]; then
  OUT="${OUT}  \033[1;37m${REPO}${RESET}"
fi

if [ -n "$BRANCH" ]; then
  OUT="${OUT}  \033[34m⎇ ${BRANCH}${RESET}"
fi

# --- レート制限 (5h / 週): statusline JSON の rate_limits があるときだけ2行目に出す ---
# rate_limits は Claude.ai サブスク(Pro/Max)かつ初回API応答後のみ入る。
# 欠落時(APIキー運用・/clear直後・冒頭)は何も足さない fail-open。
render_window() {
  # $1=ラベル $2=used_percentage $3=resets_at(epoch秒)。結果を RL_LINE に追記
  used="$2"
  [ -z "${used}" ] && return 0
  label="$1"
  reset="${3%%.*}"
  used_int="${used%%.*}"
  used_int="${used_int:-0}"
  rem=$((100 - used_int))
  [ "${rem}" -lt 0 ] && rem=0
  # 残量バー(6文字): 残量に比例。残ってるのに0マスなら最低1マス点灯
  blen=6
  filled=$((rem * blen / 100))
  [ "${filled}" -gt "${blen}" ] && filled="${blen}"
  [ "${rem}" -gt 0 ] && [ "${filled}" -eq 0 ] && filled=1
  bar=""
  i=1
  while [ "${i}" -le "${blen}" ]; do
    if [ "${i}" -le "${filled}" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    i=$((i + 1))
  done
  # 色: 残量が少ないほど危険（赤<20 / 黄<50 / 緑）
  if [ "${rem}" -lt 20 ]; then wc="\033[31m"
  elif [ "${rem}" -lt 50 ]; then wc="\033[33m"
  else wc="\033[32m"; fi
  # リセット時刻(JST): 同日は HH:MM、別日は M/D HH:MM
  rstr=""
  if [ -n "${reset}" ]; then
    rday=$(TZ=Asia/Tokyo date -r "${reset}" +%Y%m%d 2>/dev/null)
    if [ -n "${rday}" ]; then
      tday=$(TZ=Asia/Tokyo date +%Y%m%d 2>/dev/null)
      if [ "${rday}" = "${tday}" ]; then
        rstr=$(TZ=Asia/Tokyo date -r "${reset}" +%H:%M 2>/dev/null)
      else
        rstr=$(TZ=Asia/Tokyo date -r "${reset}" "+%m/%d %H:%M" 2>/dev/null)
      fi
    fi
  fi
  RL_LINE="${RL_LINE}${RL_LINE:+   }${label} ${wc}${bar} 残${rem}%${RESET}"
  [ -n "${rstr}" ] && RL_LINE="${RL_LINE} \033[90m→${rstr}${RESET}"
}

# --- Fable モデル時の注意喚起 (トークン非依存・フラグのみ) ---
# Fable の週次枠は claude.ai 上で「すべてのモデル」枠とは別集計だが、statusline JSON には
# その値が来ない(five_hour/seven_day の集計のみ)。実数は出さず注意だけ促す fail-open。
FABLE_WARN=""
case "${MODEL}" in
  *[Ff]able*) FABLE_WARN="\033[33m⚠ Fable週枠は別集計 · claude.aiで確認${RESET}" ;;
esac

RL_LINE=""
render_window "5h" "${RL5_PCT}" "${RL5_RESET}"
render_window "週" "${RL7_PCT}" "${RL7_RESET}"
[ -n "${FABLE_WARN}" ] && RL_LINE="${RL_LINE}${RL_LINE:+   }${FABLE_WARN}"

# 1行に畳むか2行に折るかを実ペイン幅($COLUMNS)で決める。
# Claude Code は tty を渡さないが COLUMNS/LINES に実サイズを入れてくれる(v2.1.153+)。
# COLUMNS 不明時や収まらない時は安全側=2行にして、狭い分割ペインでの見切れを避ける。
if [ -n "${RL_LINE}" ]; then
  sep="\n"
  if [ -n "${COLUMNS}" ]; then
    # ANSIエスケープを除いた可視文字数を数え、全角(残/週/⚠)の桁上げ分に余裕を見て判定
    plain=$(printf '%b' "${OUT}  ${RL_LINE}" | sed $'s/\033\\[[0-9;]*m//g')
    w=$(printf '%s' "${plain}" | LC_ALL=en_US.UTF-8 wc -m | tr -cd '0-9')
    [ -n "${w}" ] && [ "$((w + 8))" -le "${COLUMNS}" ] && sep="  "
  fi
  OUT="${OUT}${sep}${RL_LINE}"
fi

printf '%b' "$OUT"
