#!/bin/bash
# palmu の dev / staging Cloud SQL に read-only で繋ぐ MCP サーバー（Google MCP Toolbox）
# 使い方: cloud-sql-mcp.sh <env>   (env: staging | dev-2 | dev-3 | dev-4 | dev-5 | dev-6 | dev-7 | dev-sanya)
#
# パスワードは Keychain から取得する（設定ファイルに平文で置かない）:
#   security add-generic-password -a <ユーザー名> -s palmu-<env>-db-readonly -w '<password>'
#   例: security add-generic-password -a clawd_readonly -s palmu-stg-db-readonly -w '...'
#       security add-generic-password -a readonly -s palmu-dev-sanya-db-readonly -w '...'
#
# 本番 (palmu-prod) は意図的に対応しない。追加もしないこと。
set -euo pipefail

ENV_NAME="${1:-}"

# replica があるインスタンスは replica を優先
case "${ENV_NAME}" in
    staging)   PROJECT="palmu-staging";   INSTANCE="palmu-stg-replica";           DB_USER="clawd_readonly"; KEYCHAIN="palmu-stg-db-readonly" ;;
    dev-2)     PROJECT="palmu-dev-2";     INSTANCE="palmu-dev-2-master-v2-replica"; DB_USER="readonly";     KEYCHAIN="palmu-dev-2-db-readonly" ;;
    dev-3)     PROJECT="palmu-dev-3";     INSTANCE="palmu-dev-3-replica";         DB_USER="readonly";       KEYCHAIN="palmu-dev-3-db-readonly" ;;
    dev-4)     PROJECT="palmu-dev-4";     INSTANCE="palmu-dev-4-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-4-db-readonly" ;;
    dev-5)     PROJECT="palmu-dev-5";     INSTANCE="palmu-dev-5-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-5-db-readonly" ;;
    dev-6)     PROJECT="palmu-dev-6";     INSTANCE="palmu-dev-6-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-6-db-readonly" ;;
    dev-7)     PROJECT="palmu-dev-7";     INSTANCE="palmu-dev-7-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-7-db-readonly" ;;
    dev-sanya) PROJECT="palmu-dev-sanya"; INSTANCE="palmu-dev-sanya-master";      DB_USER="readonly";       KEYCHAIN="palmu-dev-sanya-db-readonly" ;;
    *)
        echo "不明な環境名: '${ENV_NAME}' (staging | dev-2..7 | dev-sanya)" >&2
        exit 1
        ;;
esac

PASSWORD="$(security find-generic-password -s "${KEYCHAIN}" -w 2>/dev/null)" || {
    echo "Keychain に ${KEYCHAIN} がありません。ヘッダのコメントの手順で登録してください。" >&2
    exit 1
}

export CLOUD_SQL_MYSQL_PROJECT="${PROJECT}"
export CLOUD_SQL_MYSQL_REGION="asia-northeast1"
export CLOUD_SQL_MYSQL_INSTANCE="${INSTANCE}"
export CLOUD_SQL_MYSQL_DATABASE="palmu"
export CLOUD_SQL_MYSQL_USER="${DB_USER}"
export CLOUD_SQL_MYSQL_PASSWORD="${PASSWORD}"

exec npx -y @toolbox-sdk/server --prebuilt cloud-sql-mysql --stdio
