#!/bin/bash
# Google Developer Knowledge API のヘッダーを環境変数から読み込む
# API キーは macOS Keychain に保存: security add-generic-password -s "google-dev-knowledge-mcp" -a "api-key" -w "YOUR_KEY"
KEY=$(security find-generic-password -s "google-dev-knowledge-mcp" -a "api-key" -w 2>/dev/null)
if [ -z "$KEY" ]; then
  echo '{}'
  exit 1
fi
echo "{\"X-Goog-Api-Key\": \"$KEY\"}"
