# グローバルルール

- 日本語で応答する
- feature branchで作業、mainには直接コミットしない
- 3ステップ以上のタスクはTodoWriteで管理
- テストを無効化・スキップしない
- 一時ファイルは作業後に削除
- ユーザー本人の言葉として出す文章（宣言・日報・Slack 投稿・PR 説明など）は、実態より大きく盛った言い回しを避け、作業の実状に見合った等身大の表現にする（「リード」「着手」等の誇張で鼻につかせない）
- ツール実行結果を捏造しない。副作用のある操作（投稿・記録・書き込み）は実 tool_use で発行し、成功は返り値を鵜呑みにせず直後の read で裏取りしてから「完了」と言う

## ツール利用の優先順位

- コード探索: serena MCP (`find_symbol`/`search_for_pattern`/`get_symbols_overview`) を優先
- 文字列検索: `rg`（ripgrep）を優先、`grep` は使わない
- ファイル検索: `fd` を優先、`find` は使わない
- ライブラリのドキュメント: context7 MCP を優先

## 作業の委譲先（subagent ルーティング）

作業を Task に委譲するときは内容に応じて専門エージェントを選ぶ。general-purpose は「どれにも当てはまらない汎用タスク」の最後の受け皿に留める（何でも general-purpose に投げない）。

- 調査・収集・横断検索（git/PR・Claude セッション・memory・Slack・Notion 読み取り 等）→ **investigator**（read 専用・要約で返す）
- GCP のログ・監視の調査 → **gcp-log-investigator**（参照専用）
- palmu API の仕様・実装調査 → **palmu-api-researcher**（read 専用）
- ビルド/テスト/lint の検証（失敗と原因ポインタだけ返す）→ **verify-runner**（read 専用・ソースは編集しない）
- PR レビュー指摘の読み取り・構造化（返信はしない）→ **pr-review-triage**（read 専用。書き込みは fix-pr-reviews / main）
- 広域なコード探索の fan-out → **Explore**（組み込み）
- 現在の文脈を引き継いだ独立・並行作業 → **fork**
- 上のどれにも当てはまらない汎用タスクのみ → general-purpose

実装・コミット・push・レビュー返信・リリース操作など**書き込みを伴う作業は main か専用スキル**で行う（read 専用の調査 agent には投げない）。独立した調査は 1 メッセージで並列に投げる。
