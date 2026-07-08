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
# 表示用にモデル名の括弧補足を落とす（"Opus 4.8 (1M context)" → "Opus 4.8"）。Fable判定は元のMODELで行う
MODEL_DISP="${MODEL%% (*}"
ADDED=${ADDED:-0}
REMOVED=${REMOVED:-0}
NOW=$(date +%s 2>/dev/null)

RESET="\033[0m"

# Git repo / branch（セッションの作業ディレクトリ基準。statusline プロセスの cwd に依存しない）
[ -z "$CURRENT_DIR" ] && CURRENT_DIR="$PWD"
BRANCH=$(git -C "$CURRENT_DIR" branch --show-current 2>/dev/null)
TOPLEVEL=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null)
REPO=""
[ -n "$TOPLEVEL" ] && REPO=$(basename "$TOPLEVEL")

# Build output
OUT=""
OUT="${OUT}\033[36m${MODEL_DISP}${RESET}"

if [ -n "$REPO" ]; then
  OUT="${OUT}  \033[1;37m${REPO}${RESET}"
fi

if [ -n "$BRANCH" ]; then
  OUT="${OUT}  \033[34m⎇ ${BRANCH}${RESET}"
fi

# epoch秒 → JST文字列。同日は HH:MM、別日は M/D HH:MM。失敗時は空。
fmt_time() {
  [ -z "$1" ] && return 0
  _fday=$(TZ=Asia/Tokyo date -r "$1" +%Y%m%d 2>/dev/null)
  [ -z "${_fday}" ] && return 0
  _ftoday=$(TZ=Asia/Tokyo date +%Y%m%d 2>/dev/null)
  if [ "${_fday}" = "${_ftoday}" ]; then
    TZ=Asia/Tokyo date -r "$1" +%H:%M 2>/dev/null
  else
    TZ=Asia/Tokyo date -r "$1" "+%m/%d %H:%M" 2>/dev/null
  fi
}

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
  [ "${used_int}" -lt 0 ] && used_int=0
  [ "${used_int}" -gt 100 ] && used_int=100
  # 消費バー(6文字): 使用率に比例して埋まる(使うほどリミットに近づく)。少しでも使えば最低1マス
  blen=6
  filled=$((used_int * blen / 100))
  [ "${filled}" -gt "${blen}" ] && filled="${blen}"
  [ "${used_int}" -gt 0 ] && [ "${filled}" -eq 0 ] && filled=1
  bar=""
  i=1
  while [ "${i}" -le "${blen}" ]; do
    if [ "${i}" -le "${filled}" ]; then bar="${bar}█"; else bar="${bar}░"; fi
    i=$((i + 1))
  done
  # 色: 使用率が高いほど危険（緑<50 / 黄<80 / 赤）
  if [ "${used_int}" -ge 80 ]; then wc="\033[31m"
  elif [ "${used_int}" -ge 50 ]; then wc="\033[33m"
  else wc="\033[32m"; fi
  winlen="$4"
  rstr=$(fmt_time "${reset}")

  # 消費ペース: 窓の経過割合(elapsed%)と使用率(used%)を比較。
  # 窓開始 = reset - winlen で逆算するだけ→追加データ・トークン不要。
  # used% が elapsed% を大きく超える=オーバーペース(⇡赤/枯渇ETA)、下回る=余裕(⇣緑)。
  pace=""
  timeseg=""
  if [ -n "${winlen}" ] && [ -n "${NOW}" ] && [ -n "${reset}" ]; then
    start=$((reset - winlen))
    elapsed=$((NOW - start))
    if [ "${elapsed}" -gt 0 ] && [ "${elapsed}" -le "${winlen}" ]; then
      efrac=$((elapsed * 100 / winlen))
      delta=$((used_int - efrac))
      if [ "${delta}" -ge 8 ] && [ "${used_int}" -gt 0 ]; then
        # このペースだと枯渇する時刻 = start + elapsed*100/used
        eta=$((start + elapsed * 100 / used_int))
        etastr=$(fmt_time "${eta}")
        pace=" \033[31m⇡${RESET}"
        [ -n "${etastr}" ] && timeseg=" \033[31m尽${etastr}${RESET}"
      elif [ "${delta}" -le -8 ]; then
        pace=" \033[32m⇣${RESET}"
      fi
    fi
  fi
  # オーバーペースでない(or ETA取れない)ときは通常のリセット(回復)時刻を↻付きで出す
  [ -z "${timeseg}" ] && [ -n "${rstr}" ] && timeseg=" \033[37m↻${rstr}${RESET}"

  RL_LINE="${RL_LINE}${RL_LINE:+   }${label} ${wc}${bar} \033[1m${used_int}%${RESET}${pace}${timeseg}"
}

# --- Fable モデル時の注意喚起 (トークン非依存・フラグのみ) ---
# Fable の週次枠は claude.ai 上で「すべてのモデル」枠とは別集計だが、statusline JSON には
# その値が来ない(five_hour/seven_day の集計のみ)。実数は出さず注意だけ促す fail-open。
FABLE_WARN=""
case "${MODEL}" in
  *[Ff]able*) FABLE_WARN="\033[33m⚠ Fable週枠は別集計 · claude.aiで確認${RESET}" ;;
esac

RL_LINE=""
render_window "5h" "${RL5_PCT}" "${RL5_RESET}" 18000
render_window "週" "${RL7_PCT}" "${RL7_RESET}" 604800
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
