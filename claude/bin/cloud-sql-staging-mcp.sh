#!/bin/bash
# palmu-staging の Cloud SQL replica に read-only で繋ぐ MCP サーバー（Google MCP Toolbox）
# パスワードは Keychain から取得する（設定ファイルに平文で置かない）:
#   security add-generic-password -a clawd_readonly -s palmu-stg-db-readonly -w '<password>'
# 接続先は replica 固定・read-only ユーザー固定。本番 (palmu-prod) には繋がない。
set -euo pipefail

PASSWORD="$(security find-generic-password -s palmu-stg-db-readonly -w 2>/dev/null)" || {
    echo "Keychain に palmu-stg-db-readonly がありません。ヘッダのコメントの手順で登録してください。" >&2
    exit 1
}

export CLOUD_SQL_MYSQL_PROJECT="palmu-staging"
export CLOUD_SQL_MYSQL_REGION="asia-northeast1"
export CLOUD_SQL_MYSQL_INSTANCE="palmu-stg-replica"
export CLOUD_SQL_MYSQL_DATABASE="palmu"
export CLOUD_SQL_MYSQL_USER="clawd_readonly"
export CLOUD_SQL_MYSQL_PASSWORD="${PASSWORD}"

exec npx -y @toolbox-sdk/server --prebuilt cloud-sql-mysql --stdio
