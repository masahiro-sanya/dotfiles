# グローバルルール

- 日本語で応答する
- feature branchで作業、mainには直接コミットしない
- 3ステップ以上のタスクはTodoWriteで管理
- テストを無効化・スキップしない
- 一時ファイルは作業後に削除

## ツール利用の優先順位

- コード探索: serena MCP (`find_symbol`/`search_for_pattern`/`get_symbols_overview`) を優先
- 文字列検索: `rg`（ripgrep）を優先、`grep` は使わない
- ファイル検索: `fd` を優先、`find` は使わない
- ライブラリのドキュメント: context7 MCP を優先
