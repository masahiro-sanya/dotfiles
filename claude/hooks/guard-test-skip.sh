#!/usr/bin/env bash
# Claude Code PreToolUse hook (Edit|Write|MultiEdit)
# テストファイルへのスキップ・無効化パターンの書き込みをブロックする
# （CLAUDE.md「テストを無効化・スキップしない」の機械化）
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

input="$(cat)"

file_path="$(printf '%s' "$input" | /usr/bin/jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$file_path" ] && exit 0

# テストファイル以外は対象外（"skip" という名の正当な実装コード等への誤爆を避ける）
if ! printf '%s\n' "$file_path" | /usr/bin/grep -qE '_test\.go$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)(__tests__|tests?|spec)/'; then
    exit 0
fi

content="$(printf '%s' "$input" | /usr/bin/jq -r '
    if .tool_input.new_string then .tool_input.new_string
    elif .tool_input.content then .tool_input.content
    elif .tool_input.edits then ([.tool_input.edits[].new_string] | join("\n"))
    else empty end' 2>/dev/null)"
[ -z "$content" ] && exit 0

# Go: t.Skip/Skipf/SkipNow, JS/TS: .skip( xit( xdescribe( xtest(, Python: skip デコレータ
if printf '%s\n' "$content" | /usr/bin/grep -qE '\.[Ss]kip(f|Now)?\(|(^|[^A-Za-z0-9_])x(it|describe|test)\(|@unittest\.skip|@pytest\.mark\.skip'; then
    echo "テストを無効化・スキップしない（CLAUDE.md）。skip パターンを書き込もうとしています: $file_path — テスト自体を直すか、どうしても必要ならユーザーに確認してください。" >&2
    exit 2
fi

exit 0
