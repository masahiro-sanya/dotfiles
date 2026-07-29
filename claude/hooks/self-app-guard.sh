#!/bin/bash
# self-app-guard.sh — 自作アプリ・DB 作成/デプロイコマンドの enforce フック（層2 / 施策③）
#
# PreToolUse(Bash) フック。非エンジニアがガバナンス外で「野良/自作アプリ・DB」を立てる
# 経路を端末側で塞ぐ。検出器 detect-self-app-builders.sh と同じビルダー系 CLI を対象にし、
# その「新規作成・デプロイ・プロビジョニング系」コマンドを access_policies の実効 mode で
# deny / ask / allow する。
#
# 実効 mode の取得（ローカルキャッシュ）:
#   ~/.claude/governance/self_app.mode に collector が SessionStart で
#   `policy.sh check <me> self_app` の結果（deny|ask|allow）を書く（refresh-self-app-mode.sh）。
#   フックは毎回 bq を叩かず、このキャッシュ1ファイルを読むだけ（PreToolUse は高速必須）。
#
# 既定（fail-closed）:
#   キャッシュが無い / 空 / 不明値のときは deny。
#   = 「準備が整うまで全面 deny」期間の既定挙動（対象コマンド面だけ塞ぐ。他コマンドは無干渉）。
#   認可されたエンジニア team はキャッシュが allow になるので素通りする。
#
# 設計上の限界（必読）:
#   - これは defense-in-depth の二枚目。ブラウザ完結（supabase.com を Web UI だけ）は
#     Claude Code を経由しないので、このフックでも止められない。本丸は層0（SaaS org 権限）。
#   - Bash 経由のみ可視。new-web-app / new-desktop-app 等の Skill 起動は Bash に現れないため
#     本フックの対象外（Skill レベルの enforce は別フックが必要。検出は検出器側で担保）。
#
# 入出力は Claude Code フック契約に準拠（bash-guard.sh と同形式）:
#   入力: stdin に JSON（.tool_input.command）
#   出力: permissionDecision = deny|ask（allow 相当は exit 0 で無出力）
#
# テスト用 env: SELF_APP_MODE_FILE でキャッシュパスを差し替え可能。
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$COMMAND" ] && exit 0

# --- コマンド正規化: 先頭ラッパー（cd .. && / VAR=val / サブシェル）を最大3段剥がす ---
# `cd /tmp && supabase init` のように実コマンド前にラッパーが付くと取り違えるため。
EFFECTIVE_COMMAND="$COMMAND"
for _ in 1 2 3; do
  _prev="$EFFECTIVE_COMMAND"
  EFFECTIVE_COMMAND=$(printf '%s' "$EFFECTIVE_COMMAND" | sed -E \
    -e 's/^[[:space:]]*[({][[:space:]]*//' \
    -e 's/^[[:space:]]*cd[[:space:]][^&;|]*(&&|;)[[:space:]]*//' \
    -e 's/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
  [ "$EFFECTIVE_COMMAND" = "$_prev" ] && break
done

CLI=$(basename "$(printf '%s' "$EFFECTIVE_COMMAND" | awk '{print $1}')" 2>/dev/null || true)
VERB=$(printf '%s' "$EFFECTIVE_COMMAND" | awk '{print $2}' 2>/dev/null || true)
SUB=$(printf '%s' "$EFFECTIVE_COMMAND"  | awk '{print $3}' 2>/dev/null || true)

# ビルダー系 CLI（detect-self-app-builders.sh と同期）。basemachina-api は公認のため除外。
BUILDER_RE='^(supabase|vercel|wrangler|firebase|netlify|amplify)$'
# 無害な読み取り/認証系 verb は素通り（`vercel ls` `supabase --version` 等で現場を止めない）。
# 3形に対応: 単独 verb（ls/status...）／ `noun:list` 形（firebase projects:list）／
# `noun sub` 形（vercel projects ls, supabase projects list）。
READONLY_VERB_RE='^(ls|list|status|whoami|login|logout|help|version|--version|-v|--help|-h|open|inspect|logs|info)$'
READONLY_COLON_RE='^[a-z][a-z-]*:(list|get|ls|info|status|describe)$'
READONLY_NOUN_RE='^(projects?|functions|domains|secrets|sites|teams|env|orgs|deployments|databases|apps|kv|d1|r2)$'
READONLY_SUB_RE='^(ls|list|get|info|status|describe|pull)$'

MATCHED=0
REASON_CMD=""
if printf '%s' "$CLI" | grep -qiE "$BUILDER_RE"; then
  is_readonly=0
  printf '%s' "${VERB:-}" | grep -qiE "$READONLY_VERB_RE"  && is_readonly=1
  printf '%s' "${VERB:-}" | grep -qiE "$READONLY_COLON_RE" && is_readonly=1
  if printf '%s' "${VERB:-}" | grep -qiE "$READONLY_NOUN_RE" \
     && printf '%s' "${SUB:-}" | grep -qiE "$READONLY_SUB_RE"; then is_readonly=1; fi
  if [ "$is_readonly" -eq 1 ]; then
    MATCHED=0                              # 読み取り系は対象外
  else
    MATCHED=1; REASON_CMD="$CLI ${VERB:-}" # 作成/デプロイ系（既定で対象）
  fi
fi

# スキャフォールド系: npx create-* / npm|pnpm|yarn|bun create <template>
if [ "$MATCHED" -eq 0 ]; then
  if printf '%s' "$CLI" | grep -qiE '^npx$' && printf '%s' "${VERB:-}" | grep -qiE '^create-'; then
    MATCHED=1; REASON_CMD="$CLI $VERB"
  elif printf '%s' "$CLI" | grep -qiE '^(npm|pnpm|yarn|bun)$' && printf '%s' "${VERB:-}" | grep -qiE '^create$'; then
    MATCHED=1; REASON_CMD="$CLI create ${SUB:-}"
  fi
fi

[ "$MATCHED" -eq 0 ] && exit 0            # ビルダー作成系でなければ無干渉

# --- 実効 mode をローカルキャッシュから取得 ---
MODE_FILE="${SELF_APP_MODE_FILE:-${HOME}/.claude/governance/self_app.mode}"
MODE=""
if [ -f "$MODE_FILE" ]; then
  MODE=$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null | tr 'A-Z' 'a-z' || true)
fi

case "$MODE" in
  allow) exit 0 ;;                         # 認可済み（例: エンジニア team）→ 素通り
  ask)   DECISION="ask" ;;
  *)     DECISION="deny" ;;                # deny / 未設定 / 不明 → fail-closed
esac

# JSON を壊さないよう理由に載せるコマンドは英数・記号の一部に限定する
REASON_CMD=$(printf '%s' "$REASON_CMD" | tr -cd 'a-zA-Z0-9:_./- ')

if [ "$DECISION" = "deny" ]; then
  REASON="🚫 自作アプリ・DB ガバナンス: ビルダー系コマンド「${REASON_CMD}」は現在制限されています（self_app=deny）。\\n非エンジニアの野良アプリ・DB による情報露出を防ぐための全社措置です。利用が必要な場合はリーダー経由でガバナンス担当に申請してください（access_policies で team/個人に allow を付与すると解除されます）。\\n注: これは Claude Code 経由の防御であり、ブラウザ完結の作成は別途 SaaS 組織権限（層0）で塞ぎます。"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REASON"
else
  REASON="⚠️ 自作アプリ・DB ガバナンス: ビルダー系コマンド「${REASON_CMD}」を検出（self_app=ask）。\\nこの操作はアプリ/DB の新規作成・デプロイに該当し得ます。意図した認可済みの作業ですか？\\n常用する場合はリーダー経由でガバナンス担当に申請し access_policies に登録してください。"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$REASON"
fi
exit 0
