#!/bin/bash
# palmu の dev Cloud SQL に read-only で繋ぐ MCP サーバー（Google MCP Toolbox）
# 使い方: cloud-sql-mcp.sh <env>   (env: dev-1 | dev-2 | dev-3 | dev-4 | dev-5 | dev-6 | dev-7 | dev-sanya)
#
# 認証方式は env ごとに異なる:
#   - dev-1..7 : Keychain のパスワードで readonly ユーザー接続（設定ファイルに平文を置かない）
#       security add-generic-password -a <ユーザー名> -s palmu-<env>-db-readonly -w '<password>'
#       例: security add-generic-password -a readonly -s palmu-dev1-db-readonly -w '...'
#   - dev-sanya : IAM データベース認証（パスワード不要）。ADC の identity で接続する。
#       事前に: gcloud auth application-default login   (masahiro.sanya@light-inc.com)
#       DB 側に一度だけ: GRANT SELECT ON palmu.* TO 'masahiro.sanya'@'%';
#
# 本番 (palmu-prod) は意図的に対応しない。追加もしないこと。
set -euo pipefail

ENV_NAME="${1:-}"

# 認証方式: 既定は keychain（パスワード認証）。IAM の env だけ AUTH=iam に上書きする。
# replica があるインスタンスは replica を優先
AUTH="keychain"
case "${ENV_NAME}" in
    dev-1)     PROJECT="videmeet-dev-277905"; INSTANCE="palmu-dev1-replica";        DB_USER="readonly";       KEYCHAIN="palmu-dev1-db-readonly" ;;
    dev-2)     PROJECT="palmu-dev-2";     INSTANCE="palmu-dev-2-master-v2-replica"; DB_USER="readonly";     KEYCHAIN="palmu-dev-2-db-readonly" ;;
    dev-3)     PROJECT="palmu-dev-3";     INSTANCE="palmu-dev-3-replica";         DB_USER="readonly";       KEYCHAIN="palmu-dev-3-db-readonly" ;;
    dev-4)     PROJECT="palmu-dev-4";     INSTANCE="palmu-dev-4-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-4-db-readonly" ;;
    dev-5)     PROJECT="palmu-dev-5";     INSTANCE="palmu-dev-5-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-5-db-readonly" ;;
    dev-6)     PROJECT="palmu-dev-6";     INSTANCE="palmu-dev-6-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-6-db-readonly" ;;
    dev-7)     PROJECT="palmu-dev-7";     INSTANCE="palmu-dev-7-master";          DB_USER="readonly";       KEYCHAIN="palmu-dev-7-db-readonly" ;;
    dev-sanya) PROJECT="palmu-dev-sanya"; INSTANCE="palmu-dev-sanya-master";      DB_USER="masahiro.sanya"; AUTH="iam" ;;
    *)
        echo "不明な環境名: '${ENV_NAME}' (dev-1..7 | dev-sanya)" >&2
        exit 1
        ;;
esac

export CLOUD_SQL_MYSQL_PROJECT="${PROJECT}"
export CLOUD_SQL_MYSQL_REGION="asia-northeast1"
export CLOUD_SQL_MYSQL_INSTANCE="${INSTANCE}"
export CLOUD_SQL_MYSQL_DATABASE="palmu"
export CLOUD_SQL_MYSQL_USER="${DB_USER}"

if [ "${AUTH}" = "iam" ]; then
    # password を明示的に外す → toolbox は IAM データベース認証（ADC 経由）で接続する
    # （source 実装は user と password が両方揃うときだけパスワード認証、それ以外は IAM）
    unset CLOUD_SQL_MYSQL_PASSWORD
else
    PASSWORD="$(security find-generic-password -s "${KEYCHAIN}" -w 2>/dev/null)" || {
        echo "Keychain に ${KEYCHAIN} がありません。ヘッダのコメントの手順で登録してください。" >&2
        exit 1
    }
    export CLOUD_SQL_MYSQL_PASSWORD="${PASSWORD}"
fi

exec npx -y @toolbox-sdk/server --prebuilt cloud-sql-mysql --stdio
