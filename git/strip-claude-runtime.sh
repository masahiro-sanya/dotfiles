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
#   --check     stdin の JSON に含まれるランタイムフィールドを1行1件で出力する
#               (該当なしなら何も出さない。判定は呼び出し側が行う)
#
# fail-open 設計: jq 不在 / 実行失敗 / 不正 JSON では入力をそのまま素通しし
# exit 0 する。フィルタが原因で git add / commit が壊れる事態を避ける。
# --check も同様に、判定できないときは「該当なし」を返して素通しに倒す。
#
# macOS 標準 bash 3.2 互換で記述する。

set -u

# 除外するランタイムフィールド(top-level キー)。
# 追加・削除したら CLAUDE.md の「絶対にコミットしない」記述も更新すること。
RUNTIME_KEYS="model effortLevel tui skipWorkflowUsageWarning agentPushNotifEnabled skipDangerousModePermissionPrompt"

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
output="$(printf '%s' "${input}" | jq --indent 2 "del(${del_expr})" 2>/dev/null)"
if [ $? -ne 0 ] || [ -z "${output}" ]; then
    printf '%s' "${input}"
    exit 0
fi

printf '%s\n' "${output}"
exit 0
