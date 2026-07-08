#!/usr/bin/env bash
# git/strip-claude-runtime.sh の回帰テスト（bats 不要・macOS bash 3.2 互換）
# 使い方: bash git/tests/strip-claude-runtime.test.sh
# 各ケース: JSON を stdin から filter に流し、stdout の内容/exit code を検証する

set -u

FILTER="$(cd "$(dirname "$0")/.." && pwd)/strip-claude-runtime.sh"
TMP_ROOT="$(mktemp -d)"
trap 'command rm -rf "${TMP_ROOT}"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  NG: $1"; }

# ランタイムフィールドと保持対象を両方含む入力
INPUT_FULL='{
  "theme": "dark",
  "model": "claude-opus-4-8",
  "tui": "fullscreen",
  "skipWorkflowUsageWarning": true,
  "agentPushNotifEnabled": true,
  "skipAutoPermissionPrompt": true
}'

echo "== strip-claude-runtime.sh =="

# 1. ランタイムフィールドが除去される
out="$(printf '%s' "${INPUT_FULL}" | bash "${FILTER}")"
if printf '%s' "${out}" | jq -e 'has("model") or has("tui") or has("skipWorkflowUsageWarning") or has("agentPushNotifEnabled")' >/dev/null; then
    fail "ランタイムフィールドが除去される（まだ残っている）"
else
    pass "ランタイムフィールドが除去される"
fi

# 2. コミット対象キーは残る
if printf '%s' "${out}" | jq -e '.theme == "dark" and .skipAutoPermissionPrompt == true' >/dev/null; then
    pass "theme / skipAutoPermissionPrompt は保持される"
else
    fail "theme / skipAutoPermissionPrompt は保持される（消えている）"
fi

# 3. jq 不在時は素通し（fail-open）。bash だけを持つ bin を PATH にし jq を隠す
NOJQ_BIN="${TMP_ROOT}/nojq-bin"
mkdir -p "${NOJQ_BIN}"
ln -sf "$(command -v bash)" "${NOJQ_BIN}/bash"
out_nojq="$(printf '%s' "${INPUT_FULL}" | PATH="${NOJQ_BIN}" bash "${FILTER}"; )"
rc_nojq=$?
if [ "${rc_nojq}" -eq 0 ] && [ "${out_nojq}" = "${INPUT_FULL}" ]; then
    pass "jq 不在時は入力を素通し（fail-open, exit 0）"
else
    fail "jq 不在時は入力を素通し（rc=${rc_nojq}, 内容不一致の可能性）"
fi

# 4. 不正 JSON は素通しし exit 0
broken='{ broken json'
out_broken="$(printf '%s' "${broken}" | bash "${FILTER}"; )"
rc_broken=$?
if [ "${rc_broken}" -eq 0 ] && [ "${out_broken}" = "${broken}" ]; then
    pass "不正 JSON は素通し（fail-open, exit 0）"
else
    fail "不正 JSON は素通し（rc=${rc_broken}）"
fi

# 5. 出力は末尾に改行が1つ（実ファイル整形と一致）
out_nl="$(printf '%s' "${INPUT_FULL}" | bash "${FILTER}" | wc -l | tr -d ' ')"
if [ "${out_nl}" -ge 1 ]; then
    pass "出力は改行終端の整形 JSON"
else
    fail "出力が改行終端でない"
fi

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
