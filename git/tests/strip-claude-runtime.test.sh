#!/usr/bin/env bash
# git/strip-claude-runtime.sh の回帰テスト（bats 不要・macOS bash 3.2 互換）
# 使い方: bash git/tests/strip-claude-runtime.test.sh
# 各ケース: JSON を stdin から filter に流し、stdout の内容/exit code を検証する

set -u

FILTER="$(cd "$(dirname "$0")/.." && pwd)/strip-claude-runtime.sh"
TMP_ROOT="$(mktemp -d)"
trap 'command rm -rf "${TMP_ROOT}"' EXIT

# 本物の ~/.claude/private/strip-marketplaces.txt を読ませない（存在しないパスに向ける）
export STRIP_MARKETPLACES_FILE="${TMP_ROOT}/no-such-strip-marketplaces.txt"

# 本物の ~/.claude/private/settings-plugins.json / hooks-error.log を読ませない・書かない
export STRIP_PLUGINS_SNAPSHOT="${TMP_ROOT}/no-such-dir/settings-plugins.json"
export HOOKS_ERROR_LOG="${TMP_ROOT}/hooks-error.log"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  NG: $1"; }

# ランタイムフィールドと保持対象を両方含む入力
INPUT_FULL='{
  "theme": "dark",
  "model": "claude-opus-4-8",
  "effortLevel": "high",
  "modelSettings": {"claude-opus-5-5": {"effortLevel": "high"}},
  "tui": "fullscreen",
  "skipWorkflowUsageWarning": true,
  "agentPushNotifEnabled": true,
  "skipDangerousModePermissionPrompt": true,
  "autoMode": {"allow": []},
  "skipAutoPermissionPrompt": true
}'

echo "== strip-claude-runtime.sh =="

# 1. ランタイムフィールドが除去される。
#    キー一覧はテスト側に複製せず --list（定義元）から引く。
#    定義元にキーを足したのに INPUT_FULL へ足し忘れた場合も検知する。
out="$(printf '%s' "${INPUT_FULL}" | bash "${FILTER}")"
missing_fixture=""
remaining=""
for key in $(bash "${FILTER}" --list); do
    printf '%s' "${INPUT_FULL}" | jq -e --arg k "${key}" 'has($k)' >/dev/null || missing_fixture="${missing_fixture} ${key}"
    printf '%s' "${out}" | jq -e --arg k "${key}" 'has($k)' >/dev/null && remaining="${remaining} ${key}"
done
if [ -n "${missing_fixture}" ]; then
    fail "INPUT_FULL に定義元のキーが無い:${missing_fixture}"
elif [ -n "${remaining}" ]; then
    fail "ランタイムフィールドが除去される（まだ残っている:${remaining}）"
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
   && printf '%s\n' "${check_out}" | grep -qx 'modelSettings' \
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

# 11. strip-marketplaces.txt にある marketplace は extraKnownMarketplaces / enabledPlugins から除かれる
MK_FILE="${TMP_ROOT}/strip-marketplaces.txt"
printf '%s\n' '# 注釈' 'secret-mk  # 末尾コメント' > "${MK_FILE}"
INPUT_MK='{
  "theme": "dark",
  "enabledPlugins": {"a@secret-mk": true, "b@public-mk": true, "secret-mk-updater@public-mk": true},
  "extraKnownMarketplaces": {"secret-mk": {"source": {}}, "public-mk": {"source": {}}}
}'
out_mk="$(printf '%s' "${INPUT_MK}" | STRIP_MARKETPLACES_FILE="${MK_FILE}" bash "${FILTER}")"
if printf '%s' "${out_mk}" | jq -e '(.enabledPlugins | keys) == ["b@public-mk","secret-mk-updater@public-mk"] and (.extraKnownMarketplaces | keys) == ["public-mk"] and .theme == "dark"' >/dev/null; then
    pass "strip-marketplaces.txt の marketplace が除去され、他は残る"
else
    fail "marketplace の除去結果が不正（${out_mk}）"
fi

# 12. ファイルが無ければ従来どおり（何も除かない）。--check も同じ基準で報告する
out_nomk="$(printf '%s' "${INPUT_MK}" | bash "${FILTER}")"
check_mk="$(printf '%s' "${INPUT_MK}" | STRIP_MARKETPLACES_FILE="${MK_FILE}" bash "${FILTER}" --check)"
check_nomk="$(printf '%s' "${INPUT_MK}" | bash "${FILTER}" --check)"
if printf '%s' "${out_nomk}" | jq -e '(.enabledPlugins | length) == 3 and (.extraKnownMarketplaces | length) == 2' >/dev/null \
   && [ -z "${check_nomk}" ] \
   && printf '%s\n' "${check_mk}" | grep -qx 'extraKnownMarketplaces.secret-mk' \
   && printf '%s\n' "${check_mk}" | grep -qx 'enabledPlugins.a@secret-mk' \
   && ! printf '%s\n' "${check_mk}" | grep -q 'public-mk'; then
    pass "ファイル無しは no-op、--check は同じ基準で報告する"
else
    fail "marketplace の no-op / --check が不正（${check_nomk} / ${check_mk}）"
fi

# 13. clean がスナップショットを書き、smudge が戻し、clean(smudge(x)) == clean(x)、
#     スナップショット無しの smudge は素通し
SNAP="${TMP_ROOT}/snap-dir/settings-plugins.json"
out_c="$(printf '%s' "${INPUT_MK}" | STRIP_MARKETPLACES_FILE="${MK_FILE}" STRIP_PLUGINS_SNAPSHOT="${SNAP}" bash "${FILTER}")"
if [ -f "${SNAP}" ] && jq -e '(.extraKnownMarketplaces | keys) == ["secret-mk"] and (.enabledPlugins | keys) == ["a@secret-mk"]' "${SNAP}" >/dev/null; then
    pass "clean が除去エントリをスナップショットへ保存する"
else
    fail "clean のスナップショットが不正"
fi

snap_before="$(<"${SNAP}")"
printf '%s' "${INPUT_MK}" | STRIP_MARKETPLACES_FILE="${MK_FILE}" STRIP_PLUGINS_SNAPSHOT="${SNAP}" bash "${FILTER}" >/dev/null
printf '%s' '{"theme":"dark"}' | STRIP_MARKETPLACES_FILE="${MK_FILE}" STRIP_PLUGINS_SNAPSHOT="${SNAP}" bash "${FILTER}" >/dev/null
if [ "$(<"${SNAP}")" = "${snap_before}" ]; then
    pass "除去対象 0 件ではスナップショットを消さない・書き換えない"
else
    fail "除去対象 0 件でスナップショットが変わった"
fi

out_s="$(printf '%s\n' "${out_c}" | STRIP_PLUGINS_SNAPSHOT="${SNAP}" bash "${FILTER}" --smudge)"
if printf '%s' "${out_s}" | jq -e '.enabledPlugins["a@secret-mk"] == true and (.extraKnownMarketplaces | has("secret-mk")) and (.extraKnownMarketplaces | has("public-mk")) and .theme == "dark"' >/dev/null; then
    pass "smudge がスナップショットを足し戻す"
else
    fail "smudge の結果が不正（${out_s}）"
fi

out_rt="$(printf '%s\n' "${out_s}" | STRIP_MARKETPLACES_FILE="${MK_FILE}" STRIP_PLUGINS_SNAPSHOT="${SNAP}" bash "${FILTER}")"
if [ "${out_rt}" = "${out_c}" ]; then
    pass "clean(smudge(x)) == clean(x)"
else
    fail "clean(smudge(x)) が clean(x) と異なる"
fi

in_raw="$(printf '%s\n' "${out_c}")"
out_ns="$(printf '%s\n' "${in_raw}" | STRIP_PLUGINS_SNAPSHOT="${TMP_ROOT}/none.json" bash "${FILTER}" --smudge)"
printf '{ broken' > "${TMP_ROOT}/broken-snap.json"
out_bs="$(printf '%s\n' "${in_raw}" | STRIP_PLUGINS_SNAPSHOT="${TMP_ROOT}/broken-snap.json" bash "${FILTER}" --smudge)"
if [ "${out_ns}" = "${in_raw}" ] && [ "${out_bs}" = "${in_raw}" ]; then
    pass "スナップショット無し / 壊れていると smudge は素通し"
else
    fail "smudge の素通しが不正"
fi

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
