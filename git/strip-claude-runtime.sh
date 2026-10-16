#!/usr/bin/env bash
# claude/settings.json のランタイムフィールド定義と、その除去・検査。
#
# Claude Code が実行時に書き込むランタイムフィールドを、git に格納される内容
# (index) からのみ除去する。ワーキングツリーの実ファイル(ライブ設定)は
# git がこのフィルタの出力で置き換えないため無傷のまま保持される。
#
# ここが除外キーの唯一の定義元。.githooks/pre-commit と
# .github/workflows/ci.yml は --check を呼ぶだけで、キー一覧を持たない
# (以前は3箇所が各自に一覧を持ち、食い違って commit が詰まった)。
#
# 使い方:
#   (引数なし)  git clean filter。stdin の JSON からランタイムフィールドを除いて stdout へ
#   --list      ランタイムフィールドを1行1件で出力する
#   --smudge    git smudge filter。~/.claude/private/settings-plugins.json（下記）があれば、
#               その内容を .extraKnownMarketplaces / .enabledPlugins へ足し戻して stdout へ
#   --check     stdin の JSON に含まれるランタイムフィールド（と、下記の除去対象 marketplace
#               由来のエントリ）を1行1件で出力する
#               (該当なしなら何も出さない。判定は呼び出し側が行う)
#
# 追加の除去対象: 会社固有の marketplace 名は公開リポに書けないので、git 管理外の
# ~/.claude/private/strip-marketplaces.txt（1行1名・'#' 以降は注釈・無ければ何もしない）から読む。
# 名前 M ごとに .extraKnownMarketplaces[M] と、.enabledPlugins のうちキーが "@M" で終わるものを除く。
# テスト用に STRIP_MARKETPLACES_FILE で差し替え可。
#
# スナップショット: clean が除去した marketplace 関連エントリを
# {"extraKnownMarketplaces":{...},"enabledPlugins":{...}} として
# ~/.claude/private/settings-plugins.json に保存する（STRIP_PLUGINS_SNAPSHOT で差し替え可）。
# 別ブランチの checkout / restore で除去後の blob がライブ設定へ書き戻されても、
# smudge が足し戻すので会社プラグインが黙って無効にならない。
# 書くのは内容が変わったときだけ、除去対象 0 件なら既存を消さない。
# 衝突時はスナップショットが勝つ（clean が必ず除去する対象なので index 側に正規の値は無く、
# スナップショットがライブ設定の最新の記録のため）。
#
# fail-open 設計: jq 不在 / 実行失敗 / 不正 JSON では入力をそのまま素通しし
# exit 0 する。フィルタが原因で git add / commit が壊れる事態を避ける。
# --check も同様に、判定できないときは「該当なし」を返して素通しに倒す。
#
# macOS 標準 bash 3.2 互換で記述する。

set -u

# 除外するランタイムフィールド(top-level キー)。
# 追加・削除したら CLAUDE.md の「絶対にコミットしない」記述も更新すること。
RUNTIME_KEYS="model effortLevel modelSettings tui skipWorkflowUsageWarning agentPushNotifEnabled skipDangerousModePermissionPrompt autoMode"

STRIP_MARKETPLACES_FILE="${STRIP_MARKETPLACES_FILE:-${HOME}/.claude/private/strip-marketplaces.txt}"

STRIP_PLUGINS_SNAPSHOT="${STRIP_PLUGINS_SNAPSHOT:-${HOME}/.claude/private/settings-plugins.json}"
HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"

MODE="${1:---filter}"

if [ "${MODE}" = "--list" ]; then
    for key in ${RUNTIME_KEYS}; do
        printf '%s\n' "${key}"
    done
    exit 0
fi

# stdin を一旦バッファ(fail-open で素通しできるように)。
# 外部コマンド(cat)に依存しないよう bash ビルトインの read で全体を読む。
# NUL 区切り指定で EOF まで読み込む(read は EOF で非0を返すが input は充填される)。
input=""
IFS= read -r -d '' input || true

# jq が無ければ素通し(--check は「該当なし」)
if ! command -v jq >/dev/null 2>&1; then
    [ "${MODE}" = "--check" ] && exit 0
    printf '%s' "${input}"
    exit 0
fi

# 除去対象 marketplace 名を JSON 配列にする(ファイルが無ければ [])。jq があるここ以降で使う
mk_json="[]"
if [ -f "${STRIP_MARKETPLACES_FILE}" ]; then
    mk_json="$(sed 's/#.*//' "${STRIP_MARKETPLACES_FILE}" 2>/dev/null | tr -d '[:blank:]' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)"
    [ -n "${mk_json}" ] || mk_json="[]"
fi

if [ "${MODE}" = "--smudge" ]; then
    # スナップショットが無い・壊れている・マージ失敗なら素通し
    if [ -f "${STRIP_PLUGINS_SNAPSHOT}" ]; then
        merged="$(printf '%s' "${input}" | jq --indent 2 --slurpfile snap "${STRIP_PLUGINS_SNAPSHOT}" '
            ($snap[0]) as $s
            | if ($s | type) != "object" or (type != "object") then error("bad") else . end
            | if ($s.extraKnownMarketplaces | type) == "object" then .extraKnownMarketplaces = ((.extraKnownMarketplaces // {}) + $s.extraKnownMarketplaces) else . end
            | if ($s.enabledPlugins | type) == "object" then .enabledPlugins = ((.enabledPlugins // {}) + $s.enabledPlugins) else . end' 2>/dev/null)"
        if [ $? -eq 0 ] && [ -n "${merged}" ]; then
            printf '%s\n' "${merged}"
            exit 0
        fi
    fi
    printf '%s' "${input}"
    exit 0
fi

if [ "${MODE}" = "--check" ]; then
    # select(. == "k1" or . == "k2" ...) を組み立てる
    sel_expr=""
    for key in ${RUNTIME_KEYS}; do
        if [ -n "${sel_expr}" ]; then
            sel_expr="${sel_expr} or "
        fi
        sel_expr="${sel_expr}. == \"${key}\""
    done
    # 不正 JSON 等で失敗したら「該当なし」に倒す(fail-open)
    printf '%s' "${input}" | jq -r "keys[] | select(${sel_expr})" 2>/dev/null || true
    # 除去対象 marketplace 由来のエントリ
    printf '%s' "${input}" | jq -r --argjson mk "${mk_json}" '
        ((.extraKnownMarketplaces // {}) | keys[] | select(. as $k | $mk | index($k)) | "extraKnownMarketplaces." + .),
        ((.enabledPlugins // {}) | keys[] | select(. as $k | $mk | map(. as $m | $k | endswith("@" + $m)) | any) | "enabledPlugins." + .)
    ' 2>/dev/null || true
    exit 0
fi

# del(.key1, .key2, ...) を組み立てる
del_expr=""
for key in ${RUNTIME_KEYS}; do
    if [ -n "${del_expr}" ]; then
        del_expr="${del_expr}, "
    fi
    del_expr="${del_expr}.${key}"
done

# jq で除去。失敗(不正 JSON 等)したら素通し
output="$(printf '%s' "${input}" | jq --indent 2 --argjson mk "${mk_json}" "del(${del_expr})
    | if (.extraKnownMarketplaces | type) == \"object\"
      then .extraKnownMarketplaces |= with_entries(select(.key as \$k | (\$mk | index(\$k)) | not)) else . end
    | if (.enabledPlugins | type) == \"object\"
      then .enabledPlugins |= with_entries(select(.key as \$k | (\$mk | map(. as \$m | \$k | endswith(\"@\" + \$m)) | any) | not)) else . end" 2>/dev/null)"
if [ $? -ne 0 ] || [ -z "${output}" ]; then
    printf '%s' "${input}"
    exit 0
fi

# 除去した marketplace 関連エントリをスナップショットへ保存（失敗しても出力に影響させない）
if [ "${mk_json}" != "[]" ]; then
    snap="$(printf '%s' "${input}" | jq --indent 2 --argjson mk "${mk_json}" '
        {extraKnownMarketplaces: ((.extraKnownMarketplaces // {}) | with_entries(select(.key as $k | ($mk | index($k)) != null))),
         enabledPlugins: ((.enabledPlugins // {}) | with_entries(select(.key as $k | ($mk | map(. as $m | $k | endswith("@" + $m)) | any))))}' 2>/dev/null)"
    if [ -n "${snap}" ] && [ "$(printf '%s' "${snap}" | jq '(.extraKnownMarketplaces | length) + (.enabledPlugins | length)' 2>/dev/null)" != "0" ]; then
        cur=""
        [ -f "${STRIP_PLUGINS_SNAPSHOT}" ] && cur="$(<"${STRIP_PLUGINS_SNAPSHOT}")"
        if [ "${cur}" != "${snap}" ]; then
            if ! { mkdir -p "$(dirname "${STRIP_PLUGINS_SNAPSHOT}")" \
                   && printf '%s\n' "${snap}" > "${STRIP_PLUGINS_SNAPSHOT}.tmp.$$" \
                   && mv -f "${STRIP_PLUGINS_SNAPSHOT}.tmp.$$" "${STRIP_PLUGINS_SNAPSHOT}"; } 2>/dev/null; then
                command rm -f "${STRIP_PLUGINS_SNAPSHOT}.tmp.$$" 2>/dev/null
                printf '%s strip-claude-runtime: snapshot write failed: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${STRIP_PLUGINS_SNAPSHOT}" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
            fi
        fi
    fi
fi

printf '%s\n' "${output}"
exit 0
