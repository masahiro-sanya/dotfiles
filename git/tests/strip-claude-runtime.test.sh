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
  "effortLevel": "high",
  "tui": "fullscreen",
  "skipWorkflowUsageWarning": true,
  "agentPushNotifEnabled": true,
  "skipAutoPermissionPrompt": true
}'

echo "== strip-claude-runtime.sh =="

# 1. ランタイムフィールドが除去される
out="$(printf '%s' "${INPUT_FULL}" | bash "${FILTER}")"
if printf '%s' "${out}" | jq -e 'has("model") or has("effortLevel") or has("tui") or has("skipWorkflowUsageWarning") or has("agentPushNotifEnabled")' >/dev/null; then
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

# 6. --list はキーを1行1件で出す
list_out="$(bash "${FILTER}" --list)"
if [ "$(printf '%s\n' "${list_out}" | wc -l | tr -d ' ')" -ge 5 ] \
   && printf '%s\n' "${list_out}" | grep -qx 'effortLevel'; then
    pass "--list はランタイムフィールドを1行1件で出す"
else
    fail "--list の出力が不正"
fi

# 7. --check は含まれるランタイムフィールドだけを報告する
check_out="$(printf '%s' "${INPUT_FULL}" | bash "${FILTER}" --check)"
if printf '%s\n' "${check_out}" | grep -qx 'model' \
   && printf '%s\n' "${check_out}" | grep -qx 'effortLevel' \
   && ! printf '%s\n' "${check_out}" | grep -qx 'theme'; then
    pass "--check は該当キーだけを報告する"
else
    fail "--check の報告内容が不正（${check_out}）"
fi

# 8. --check は該当なしなら何も出さない
clean_out="$(printf '%s' '{"theme":"dark"}' | bash "${FILTER}" --check)"
if [ -z "${clean_out}" ]; then
    pass "--check は該当なしなら何も出さない"
else
    fail "--check が余計な出力をした（${clean_out}）"
fi

# 9. --check は不正 JSON でも fail-open（何も出さず exit 0）
bad_out="$(printf '%s' "${broken}" | bash "${FILTER}" --check)"
rc_bad=$?
if [ "${rc_bad}" -eq 0 ] && [ -z "${bad_out}" ]; then
    pass "--check は不正 JSON で fail-open"
else
    fail "--check が不正 JSON で fail-open しない（rc=${rc_bad}）"
fi

# 10. 定義元と consumer（pre-commit / CI）が食い違っていない。
#     以前は3箇所が各自にキー一覧を持ち、食い違って commit が詰まった。
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
drift=0
for consumer in "${REPO_ROOT}/.githooks/pre-commit" "${REPO_ROOT}/.github/workflows/ci.yml"; do
    if grep -q 'skipWorkflowUsageWarning' "${consumer}" 2>/dev/null; then
        fail "$(basename "${consumer}") がキー一覧を自前で持っている（--check に委ねること）"
        drift=1
    fi
done
[ "${drift}" -eq 0 ] && pass "pre-commit / ci.yml はキー一覧を持たず --check に委ねている"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
