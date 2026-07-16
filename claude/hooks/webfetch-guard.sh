#!/bin/bash
# webfetch-guard.sh — PreToolUse hook (WebFetch)
# WebFetch は sandbox の network.allowedDomains 対象外 = 任意ホストへの GET exfil 経路。
# (1) URL に既知の秘密パターン(APIキー/トークン/秘密鍵/JWT) → ask（許可ドメインでも）
# (2) host が webfetch-allowed-domains.txt に一致 → allow
# (3) 未知ドメイン: 外送ペイロードを評価
#     (3a) https・userinfo無し・クエリ無し・IP/punycode無し・長い不透明トークン無し
#          = 外送帯域ほぼゼロの GET → allow（payload-aware な狭い緩和 / v1.15.2）
#     (3b) 上記いずれか該当 → ask。理由文に検出フラグを添えて判断を速くする（判断補助）
# 長い base64/hex の網羅検査は git SHA / 検索クエリ / 署名付き URL を誤検知するため、
# allow を絞る側(=誤検知は ask に倒れ安全側)にのみ使い、ask を増やす側には使わない。
set -uo pipefail
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0
URL=$(printf '%s' "$INPUT" | jq -r '.tool_input.url // empty' 2>/dev/null || true)
[ -z "${URL:-}" ] && exit 0

# (1) 既知の秘密パターン（query/path/host のどこに出ても）
if printf '%s' "$URL" | grep -qE 'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sk-(ant-)?[A-Za-z0-9_-]{20,}|-----BEGIN|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}'; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"🔑 WebFetch ガード: URL に秘密情報らしきパターン(APIキー/トークン/JWT/秘密鍵)を検出。context 内の機密を外部へ送ろうとしていないか確認してください。\"}}"
  exit 0
fi

# authority([user@]host[:port]) / scheme / 実 host を抽出（userinfo を剥がす = "@偽装"対策）
AUTHORITY=$(printf '%s' "$URL" | sed -nE 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]+).*#\1#p')
SCHEME=$(printf '%s' "$URL" | sed -nE 's#^([a-zA-Z][a-zA-Z0-9+.-]*)://.*#\1#p' | tr '[:upper:]' '[:lower:]')
HOST=$(printf '%s' "$AUTHORITY" | sed -E 's#^[^@]*@##; s#:[0-9]+$##' | tr '[:upper:]' '[:lower:]')

ALLOWFILE="${HOME}/.claude/hooks/webfetch-allowed-domains.txt"
matched=0
if [ -n "$HOST" ] && [ -f "$ALLOWFILE" ]; then
  while IFS= read -r dom; do
    dom=$(printf '%s' "$dom" | sed 's/#.*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -z "$dom" ] && continue
    if [ "$HOST" = "$dom" ]; then matched=1; break; fi
    case "$HOST" in *."$dom") matched=1; break;; esac
  done < "$ALLOWFILE"
fi

# (2) 許可ドメイン → allow
if [ "$matched" -eq 1 ]; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"✅ WebFetch: 許可ドメイン (${HOST})\"}}"
  exit 0
fi

# (3) 未知ドメイン: 外送ペイロードの兆候を集める（1つでも立てば ask）
flags=""
[ -z "$HOST" ] && flags="${flags}host解析不能・"
[ "$SCHEME" != "https" ] && flags="${flags}非https・"
case "$AUTHORITY" in *@*) flags="${flags}user@偽装・";; esac
case "$HOST" in xn--*|*.xn--*) flags="${flags}punycode・";; esac
case "$AUTHORITY" in \[*) flags="${flags}IPv6直書き・";; esac
printf '%s' "$HOST" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && flags="${flags}IP直書き・"
case "$URL" in *\?*) flags="${flags}クエリ文字列・";; esac
# 24+ 連続の英数字/_/= = 不透明トークン/エンコード塊の疑い（host ラベル・path 双方を走査）
printf '%s' "$URL" | grep -qE '[A-Za-z0-9_=]{24,}' && flags="${flags}長い不透明トークン・"

# (3a) フラグ皆無 = 外送ペイロードほぼゼロの https GET → 未知ドメインでも allow（狭い緩和）
if [ -z "$flags" ]; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"✅ WebFetch: 未知ドメイン (${HOST}) だが外送ペイロード無し(https・クエリ無し・不透明トークン無し)のため自動許可。常用するなら webfetch-allowed-domains.txt に追記推奨。\"}}"
  exit 0
fi

# (3b) フラグあり → ask（検出フラグを添えて判断補助）
echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"🌐 WebFetch ガード: 許可リスト外ドメイン (${HOST:-解析不能})｜⚠検出: ${flags%・}。URL に context 内の機密が乗っていないか確認を。常用するなら ~/.claude/hooks/webfetch-allowed-domains.txt に追記すれば以後無確認。\"}}"
exit 0
