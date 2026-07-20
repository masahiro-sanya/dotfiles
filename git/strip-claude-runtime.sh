#!/usr/bin/env bash
# git clean filter for claude/settings.json
#
# Claude Code が実行時に書き込むランタイムフィールドを、git に格納される内容
# (index) からのみ除去する。ワーキングツリーの実ファイル(ライブ設定)は
# git がこのフィルタの出力で置き換えないため無傷のまま保持される。
#
# 除外対象キーは CLAUDE.md の「絶対にコミットしない」記述と同期させること。
#
# fail-open 設計: jq 不在 / 実行失敗 / 不正 JSON では入力をそのまま素通しし
# exit 0 する。フィルタが原因で git add / commit が壊れる事態を避ける。
#
# macOS 標準 bash 3.2 互換で記述する。

set -u

# 除外するランタイムフィールド(top-level キー)
RUNTIME_KEYS="model tui skipWorkflowUsageWarning agentPushNotifEnabled"

# stdin を一旦バッファ(fail-open で素通しできるように)。
# 外部コマンド(cat)に依存しないよう bash ビルトインの read で全体を読む。
# NUL 区切り指定で EOF まで読み込む(read は EOF で非0を返すが input は充填される)。
input=""
IFS= read -r -d '' input || true

# jq が無ければ素通し
if ! command -v jq >/dev/null 2>&1; then
    printf '%s' "${input}"
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
