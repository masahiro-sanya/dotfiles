#!/bin/bash
# credential-guard.sh — Read ツールが認証情報ファイルを読もうとしたら確認を求める
set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# ヘルパー: ファイルが git 管理下のリポジトリ内かを判定する。
# .sql 系の Layer B (パスベース dump 検出) で「リポジトリ内 = 開発成果物としての SQL」を
# 除外するために使う。git コマンドは呼ばず、親ディレクトリを辿って .git の存在をチェックする。
# ⚠️ symlink 経由の bypass を防ぐため、判定前に realpath で物理パスに正規化する。
# 例: ~/git-repo/link-to-dump → ~/Downloads/users.sql のような symlink で git repo 外の
#     dump を読むケースを防ぐ。realpath が利用可能な macOS 13+ は標準コマンド、
#     利用不可な環境では `cd -P && pwd` でフォールバック。
in_git_repo() {
  local dir="$1"
  local resolved=""
  if command -v realpath >/dev/null 2>&1; then
    resolved=$(realpath "$dir" 2>/dev/null)
  else
    resolved=$( (cd -P "$dir" 2>/dev/null && pwd) || true )
  fi
  [ -n "$resolved" ] && dir="$resolved"
  while [ "$dir" != "/" ] && [ "$dir" != "." ] && [ -n "$dir" ]; do
    [ -e "$dir/.git" ] && return 0
    dir=$(dirname "$dir")
  done
  return 1
}

# .env 系ファイル
if echo "$BASENAME" | grep -qiE '^\.env($|\.)'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"⚠️ 認証情報を含む可能性のあるファイル (.env) を読み取ろうとしています。"}}'
  exit 0
fi

# token.json
if echo "$BASENAME" | grep -qiE '^token.*\.json$'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"⚠️ OAuthトークンファイルを読み取ろうとしています。"}}'
  exit 0
fi

# credentials / secret / key 系
if echo "$BASENAME" | grep -qiE '(credential|secret|private.key|\.pem$|\.key$|api.key)'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"⚠️ 認証情報・秘密鍵ファイルを読み取ろうとしています。"}}'
  exit 0
fi

# 汎用 secret config / service account JSON
# 例: secrets.yaml, secret.json, service-account-key.json, db-secret.yml
if echo "$BASENAME" | grep -qiE '^secrets?\.(ya?ml|json|env|toml)$|service[-_]account.*\.json$'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"⚠️ 機密設定ファイル (secret config / service account) を読み取ろうとしています。"}}'
  exit 0
fi

# DB dump / SQLite ファイル — 顧客データを含む可能性
# 2 層構成:
#   Layer A: ファイル名で明示的な dump prefix (dump/backup/export) や DB 拡張子 (.sqlite/.db)。
#            ファイルがどこにあっても無条件で ask（git 内でも対象）。
#   Layer B: .sql / .sql.gz 等で「ORM の schema 系ディレクトリ (migrations/seeds/etc) を含まない」
#            「かつ git リポジトリ外」のもの。`~/Downloads/users.sql` / `prod.sql.gz` 等の
#            無修飾 dump をキャッチしつつ、リポジトリ内の開発成果物 SQL (BigQuery クエリ /
#            アクション SQL / drizzle / docker mysql init 等) は誤検知しない設計。
# 注: grep -E (POSIX ERE) に \d は無いため数字は [0-9] で表す。

# Layer A: ファイル名ベース
if echo "$BASENAME" | grep -qiE '\.sqlite[0-9]?$|\.db$|(dump|backup|export).*\.(sql|json|csv|jsonl)(\.(gz|bz2|zip|xz))?$'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"⚠️ データベースダンプ / SQLite ファイルを読み取ろうとしています。顧客データを含む可能性があります。"}}'
  exit 0
fi

# Layer B: .sql / .sql.gz 等で schema 系ディレクトリ外 かつ git リポジトリ外
# 検出する ORM 慣習ディレクトリ:
#   - Rails: db/migrate/, db/seeds/
#   - Django: <app>/migrations/
#   - Prisma: prisma/migrations/
#   - Supabase: supabase/migrations/
#   - Sequelize/Knex/TypeORM: migrations/, seeders/
#   - Flyway: db/migration/
#   - Liquibase: db/changelog/
#   - SQLAlchemy/Alembic: migrations/versions/  (← migrations の中なので migrations で match)
#   - 一般: schema/, fixtures/
# ⚠️ versions/ は単独パスセグメントとして match させない (`~/Downloads/versions/prod.sql`
#    のような単独 versions パスは schema 系ではないため)。Alembic は migrations/ で先に
#    match するので versions/ の単独 pattern は不要。
# git リポジトリ内除外を入れる理由: リポジトリ内の .sql は開発成果物
#   (BigQuery アクション / scheduled-queries / drizzle / docker init 等) の可能性が高く、
#   誤検知が大量に発生する (実環境で 234 件確認)。リポジトリ内に dump を置く運用は
#   別の防御層 (/security-audit Step 2-b: git tracked 機密ファイル検出) でカバー。
SCHEMA_PATH_PATTERN='(^|/)(migrations?|migrate|seeds?|seeders?|fixtures?|schema|changelog)/'
if echo "$BASENAME" | grep -qiE '\.sql(\.(gz|bz2|zip|xz))?$' \
   && ! echo "$FILE_PATH" | grep -qiE "$SCHEMA_PATH_PATTERN" \
   && ! in_git_repo "$(dirname "$FILE_PATH")"; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"⚠️ git リポジトリ外の .sql ファイルを読み取ろうとしています (DB dump の可能性)。承認するか、永続許可したい場合は credential-guard.sh を編集してください。"}}'
  exit 0
fi

exit 0
