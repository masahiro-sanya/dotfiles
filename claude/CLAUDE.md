# グローバルルール

- 日本語で応答する
- feature branchで作業、mainには直接コミットしない
- 3ステップ以上のタスクはTodoWriteで管理
- テストを無効化・スキップしない
- 一時ファイルは作業後に削除
- ユーザー本人の言葉として出す文章（宣言・日報・Slack 投稿・PR 説明など）は、実態より大きく盛った言い回しを避け、作業の実状に見合った等身大の表現にする（「リード」「着手」等の誇張で鼻につかせない）
- ユーザー向けの文章（Notion・Slack・GitHub・PR・チケット・設計など）で、ユーザーが使っていない新しい用語・カタカナ語・略語を勝手に持ち込まない。会話や元資料でユーザーが使っている語をそのまま使う（例:「手順書」を「runbook」に言い換えない、「9タイル」「uptime」等の出どころ不明な語を独断で導入しない）。新しい概念名がどうしても必要なときは、ユーザーの言葉に寄せるか一言確認してから使う
- ツール実行結果を捏造しない。副作用のある操作（投稿・記録・書き込み）は実 tool_use で発行し、成功は返り値を鵜呑みにせず直後の read で裏取りしてから「完了」と言う
- サブエージェント（Task）を起動したら、「走っている／投げた」と言い切る前に、起動時の返り値（agent ID）と TaskOutput（block:false）の生存確認で実際に走っているかを裏取りする（TaskList は TODO 一覧でサブエージェントは載らない＝起動の裏取りには使えない。完了済み agent への TaskOutput は「No task found」になり結果は完了通知で届く＝失敗ではない）。裏取りできないなら放置せず投げ直すか状況を正直に報告する。起動後も完了まで見届け、無反応が続けば生存を確認する。空振りのまま「実行中」と述べない（＝走っていない処理を実行中と報告するのは実質ツール結果の捏造）

## ツール利用の優先順位

- コード探索: serena MCP (`find_symbol`/`search_for_pattern`/`get_symbols_overview`) を優先
- 文字列検索: `rg`（ripgrep）を優先、`grep` は使わない
- ファイル検索: `fd` を優先、`find` は使わない
- ライブラリのドキュメント: context7 MCP を優先
- memory（運用知見）の書き込みは `~/.claude/projects/*/memory`（`MEMORY.md` 索引 + 個別 md）に一元化する。serena の `write_memory` は使わない（serena memory は読むだけ。二重管理を避ける）

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

実装・コミット・push・レビュー返信・リリース操作など**書き込みを伴う作業は read 専用の調査 agent には投げない**。ただし**独立して仕様が閉じた実装スライス**（例: テーブル追加＋ハンドラ＋テストのような定型）は、`superpowers` の subagent-driven-development / dispatching-parallel-agents の型で書き込み可能な fresh agent に切り出してよい。フル文脈と人間の舵取りが要る実装だけ main に残す。**独立した調査・読み取りは必ず複数 Task を 1 メッセージで同時に投げる（1 本ずつ順番に投げない）。1 本の investigator に多ソースを詰め込むと中で逐次読みになって遅い＝独立ソースは別 Task に割って並列度を上げる**（読みが遅いと感じたら本数を増やす／太い 1 本を割る）。
