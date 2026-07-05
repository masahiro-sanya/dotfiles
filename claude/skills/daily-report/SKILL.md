---
name: daily-report
description: 日報サイクル。朝は前日の採点（Notion 評価軸レビュー）を踏まえて「今日のタスクと目標」を宣言、夜は当日の作業実績（コミット・PR 活動・Claude セッション・memory・Slack）をサブエージェントで横断収集して朝の宣言と突き合わせ、アウトカム中心の日報を作る。夜は加えて評価者目線の辛口採点を専用 Notion ログへ追記する。投稿は承認後のみ。Use when user says "日報", "daily report", "/daily-report", "今日のまとめ", "今日やること", "評価チェック", "評価軸レビュー".
allowed-tools: Task, Bash(git -C *), Bash(gh search prs *), Bash(gh pr list *), Bash(fd *), Bash(jq *), Bash(head *), Bash(cat *), Bash(date), Read, Write, mcp__plugin_slack_slack__slack_send_message, mcp__plugin_slack_slack__slack_search_public_and_private, mcp__plugin_slack_slack__slack_read_thread, mcp__notion__notion-query-data-sources, mcp__notion__notion-fetch, mcp__notion__notion-create-pages
---

# 日報サイクル

**朝に宣言 → 夜に宣言と突き合わせて振り返る** 個人ワークフロー。
背景: 作業の可視化ギャップを潰すのが目的。作業ログの羅列ではなく「宣言に対して何がどこまで進んだか」に翻訳する。

宣言と日報は `~/.claude/daily-report/YYYY-MM-DD.md` に保存し、夜の突き合わせと翌朝の引き継ぎに使う。

## モード判定

- 「今日やること」「日報 朝」など**開始時** → 朝モード（宣言）
- 「日報」「今日のまとめ」など**終了時** → 夜モード(振り返り)。当日ファイルに宣言が無ければ「宣言なし」として進める（催促しない）
- 「評価チェックだけ」「評価軸レビュー」→ **評価のみモード**。夜モードのうち step 1-3（実績収集）＋ step 5（採点）だけを実行し、日報本体は組まず Slack 投稿もしない（Notion ログへの追記のみ）

## 評価の参照先（非公開設定）

このリポは公開。**評価採点で使う Notion ID・DB・career-feed パスはスキルに書かず、ローカル非公開設定から読む**:
`~/.claude/daily-report/eval-config.json`（リポ管理外・git に含めない）。想定キー:

```json
{
  "log_db":                "collection://…",     // 評価軸レビュー（日次ログ）DB（クエリ用）
  "log_db_data_source_id": "…",                  // 同 DB の data_source_id（追記用）
  "criteria_page":         "…",                  // 📏 採点基準ページ
  "achievements_page":     "…",                  // 📝 実績メモ（キャリア棚卸し）
  "oneonone_collection":   "collection://…",     // 1on1 ノート DB
  "career_memory_index":   "~/.claude/projects/…/MEMORY.md"  // career-feed memory 索引
}
```

**評価に触れる前（朝 step 2 / 夜 step 5）に、まずこのファイルを `cat` で読む**。以降この文書の `{log_db}` `{criteria_page}` 等はここの値を指す。
**ファイルが無ければ評価パートは ⚠️ で丸ごとスキップ**し、日報本体（朝の宣言・夜の振り返り）は通常どおり進める（評価が無くても止めない）。

## 朝モード: 今日のタスクと目標を宣言する

材料を集めて「今日のタスク内容と目標」を作る:

1. 前日（直近）の `~/.claude/daily-report/*.md` の「明日やること」を読む
2. **前日の採点を読む（＝今日の目標を立てる軸。最重要）**。夜モードで Notion に付けた辛口採点を引き継ぎ、今日の目標に反映する:
   - 先に eval-config.json を読む（無ければこの step は ⚠️ でスキップ）。`notion-query-data-sources` で直近の採点行を取る（`{log_db}`。以下 SQL の `{log_db}` は設定値に置換）:
     ```sql
     SELECT "日付", "実施日", "スピード/工数", "見積もり精度", "セルフレビュー", "優先順位", "1on1反応", "黄信号", "明日への一手", "総評"
     FROM "{log_db}" ORDER BY "実施日" DESC LIMIT 3
     ```
   - 実データの最新 1 行を使う（`📝 記入例`＝実施日が空の行は除外）。読めない / 前日採点が無い時は ⚠️ で明示し、前日ファイルの「明日やること」だけを軸に進める（催促しない）
3. 自分のオープン PR を確認: `gh search prs --author=@me --state=open --json url,title,repository,updatedAt --limit 30`
4. ユーザーと 1-2 往復で確定し、当日ファイルに保存する:

```
## 宣言 YYYY-MM-DD

（前日採点の引き継ぎ: 明日への一手=<...> / △×だった軸=<...>）
- <タスク>: <今日どこまで進めるか（目標を測れる形で。例: 設計レビュー依頼まで / PR マージまで）>
- ...
```

目標は「やる」でなく **「どこまで行ったら達成か」** が分かる形で書く（夜の予定比の基準になる）。

**前日採点を目標に落とす（step 2 が取れた時は必須）:**
- 前日の **「明日への一手」を今日のタスクに 1 つ以上落とす**（一手をやり切ることが最優先の目標）
- **△ / × が付いた軸**を今日どう改善するかを目標に織り込む（同じ軸で連日 △× を出さない）
- 前日の **黄信号**を今日潰す動きを入れる
- ◎ が続く軸は維持を確認するだけでよく、伸びしろは弱い軸へ回す

**精神論禁止**: 「今日は頑張る」「結構進める」「取り返す」だけで止めない。**必ず「どのタスクで・どこまで行けば挽回か」に翻訳する**。
- ✗「昨日進まなかったので今日は進める」
- ◎「スピード=△だった → A機能のPRを今日レビュー依頼まで出す（残工数を着手前に宣言してから触る）」
弱かった軸は、それを取り返す具体タスクと達成ラインに必ず結びつける。抽象的な決意表明は目標として書かない。

## 夜モード: 収集して振り返る

**収集（調査）は全てサブエージェントに委譲する。** step 1-3 の各ソースを `Task`（general-purpose）に投げ、**生ログではなく要約だけ**を返させる（main の文脈を汚さない）。4 ソースは独立なので **1 メッセージで並列に投げる**。返ってきた要約だけを step 4-5 の入力にする。サブエージェントには「収集専任。ファイルは変更しない。当日分だけ・PR/コミット/スレッドの URL を付けて要約を返す」と伝える。あるソースが 0 件/エラーでも他は止めない（⚠️ 明示）。

各サブエージェントに渡す調査内容:

### 1. 当日のコミットを横断収集

```bash
today=$(date +%F)
for d in $(fd -H -t d '^\.git$' ~/src --max-depth 4 -x dirname {} | sort -u); do
  log=$(git -C "${d}" log --all --since="${today} 00:00" --author="$(git -C "${d}" config user.email)" --oneline 2>/dev/null)
  [ -n "${log}" ] && printf '## %s\n%s\n' "${d}" "${log}"
done
```
→ リポごとに「何をしたか」を 1-2 行へ要約して返す（ハッシュ羅列にしない）。

### 2. 当日の PR 活動を収集

作成・更新・マージ・レビューの 4 観点。スコープはグローバル検索（light-inc / light-inc-sub / palmu 系を含む）:

```bash
today=$(date +%F)
# 自分の PR で今日動いたもの（作成・更新・マージ）
gh search prs --author=@me --json url,title,repository,state,updatedAt --limit 30 -- "updated:>=${today}"
# 今日レビューした他人の PR
gh search prs --reviewed-by=@me --json url,title,repository,author --limit 30 -- "updated:>=${today}"
```

フラグがエラーになったら `gh search prs --help` で確認して読み替える（結果ゼロとエラーを混同しない）。

### 3. 当日の Claude セッション・memory・Slack を確認

git/PR に現れない作業（調査・設計・レビュー・運用対応・**Slack での議論**）をここで拾う。**これが可視化ギャップの本丸**。以下 3 つを 1 サブエージェントにまとめて調べさせてよい:

```bash
# 当日触ったプロジェクトとプロンプト概要（スキーマは実物を head で確認してから jq を書く）
head -1 ~/.claude/history.jsonl
jq -r 'select(.timestamp != null)' ~/.claude/history.jsonl | tail -50   # 当日分に絞って集計
# 今日更新された memory（進行中タスクの根拠になる）
fd . ~/.claude/projects --glob '*.md' --changed-within 1d
```

- **Slack（調査・相談・運用対応の一次ソース。ユーザーは日報でこれを見ることに同意済み）**: 当日の自分の発言・スレッドを検索する
  - `slack_search_public_and_private` で query = `from:<@自分の user_id> on:<当日 YYYY-MM-DD>`、`sort=timestamp`（自分の user_id はツール説明に `Current logged in user's user_id is …` として表示されるのでそれを使う。公開リポに ID を直書きしない）
  - private チャンネル/DM でも調査・相談が起きるので public 限定にしない
  - 目ぼしいスレッドは `slack_read_thread` で深掘りし、「何を調べ / 決め / 対応したか」を要約（雑談は落とす）
→ サブエージェントは Claude セッション・memory・Slack を横断し、成果につながる動きだけを URL 付きで要約して返す。

### 4. 朝の宣言と突き合わせて日報を組み立てる

当日ファイルの宣言を読み、収集結果を以下に **翻訳** する（コミットメッセージの転記ではなく、成果の言葉にする）:

```
## 日報 YYYY-MM-DD

### 今日の成果（アウトカム）
- <完了したこと。「何が使える/直った/決まった状態になったか」で書く。PR リンク付き>

### 振り返り（宣言との突き合わせ）
- <宣言タスクごとに: 達成 / 目標まで残り X / 未着手（理由）。予定比を一言（予定どおり / 半日遅れ・理由は X）>
- <宣言に無かったが発生した作業（割り込み・運用対応）もここに。時間を食った要因の可視化>

### 進行中
- <どこまで進んだか + 残り + 完了見込み>

### ブロッカー / 相談
- <待ち・詰まり。なければ「なし」>

### 明日やること
- <優先順に 2-3 個。翌朝の宣言の種になる>
```

- 振り返りを空欄にしない（最低でも予定比 1 行）。宣言が無い日は成果ベースで振り返る
- 成果が多い日は重要な 3-5 個に絞る（全部書かない）
- 秘匿情報（API キー・顧客データ・未公開の人事情報）は書かない

日報本体はここまで。当日ファイルに追記保存する（ユーザーへの提示は step 5 の採点まで終えてから一括で行う）。

### 5. 評価軸レビュー（辛口 / Notion ログへ追記）

step 1-4 で見えた当日の成果・振り返りを入力に、最終評価者目線で辛口採点し、専用 Notion DB に **1 日 1 行** 追記する。
**この採点は Slack には流さない**（#daily-sanya へ出すのは日報本体だけ。採点は自分用の Notion ログに閉じる）。

**採点基準はスキルに持たない。毎回 Notion の「📏 採点基準」ページを読み、それに従って採点する**（現在地・等級・5 軸それぞれの見るポイント・◎ の水準・読むべき evidence とその重み・トーンは全部そのページにある。基準は四半期ごとに人間が更新するので、スキル側は機構だけ持つ）:

0. **eval-config.json を読む**（無ければこの step 5 は ⚠️ で丸ごとスキップ）。以下の `{criteria_page}` 等はその値。
1. **採点基準ページを読む**: `notion-fetch` で page id = `{criteria_page}`
2. **基準ページが指す evidence を読んで採点する**（cwd に関わらず絶対パス / ID で読む。daily-report は他プロジェクトから走ることが多く自動想起されないため明示的に読む。読めない時は ⚠️ で明示して best-effort で採点し、後続を止めない）。基準ページに evidence の詳細（何を・どの重みで見るか）があるが、機械的な取得先は下記:
   - career-feed project memory: Read `{career_memory_index}`（索引）＋基準ページが指す個別ファイル
   - 最新 1on1 ノート: `notion-query-data-sources` で `SELECT url, createdTime, "名前" FROM "{oneonone_collection}" ORDER BY createdTime DESC LIMIT 1` → 得た `url` を `notion-fetch`
   - 📝 実績メモ（キャリア棚卸し）: `notion-fetch` で page id = `{achievements_page}`
3. **採点する**: 基準ページの 5 軸を ◎○△× で採点し（下記 DB カラムに対応）、加点材料 / 黄信号 / 明日への一手 / 総評 を付ける。◎ 連発をしない。辛口を貫く。秘匿情報（未公開の人事情報含む）は Notion ログにも書かない（詳細な採点観点・トーンは基準ページに従う）。

**Notion DB へ追記（承認後）:**

- DB: 「評価軸レビュー（日次ログ）」 → data source `{log_db}`（追記の parent は `{log_db_data_source_id}`）
- `notion-create-pages` で 1 行 append する（プロパティ名は下記のとおり厳密に。**日付型は expanded キー `date:実施日:start` で渡す**。select は ◎○△× のいずれか）:
  ```
  parent: { type: "data_source_id", data_source_id: "{log_db_data_source_id}" }
  properties:
    "日付": "YYYY-MM-DD"                 # title（当日の日付文字列）
    "date:実施日:start": "YYYY-MM-DD"    # date 型。集計はこの列の範囲で行う
    "スピード/工数": "◎|○|△|×"
    "見積もり精度": "◎|○|△|×"
    "セルフレビュー": "◎|○|△|×"
    "優先順位":     "◎|○|△|×"
    "1on1反応":     "◎|○|△|×"
    "加点材料":     "<今日、評価で効く動き。無ければ「なし」>"
    "黄信号":       "<評価者に突かれそうな点。無ければ「なし」>"
    "明日への一手": "<黄信号を潰す / 加点を伸ばす具体行動 1 つ>"
    "総評":         "<1 行。今日の動きは目標水準に届いたか（基準は採点基準ページの現在地に従う）>"
  ```

採点行のプレビューはユーザーに提示する（step 4 の日報本体とまとめて提示）。承認されたら Notion へ追記し、追記した行の URL を当日ファイルにも記録する。

## 投稿

宣言（朝）・日報本体（夜）とも、ユーザーが文面を承認したら **#daily-sanya (C04CBF2JWAD) へ投稿するまでが標準フロー**。投稿後はメッセージリンクを当日ファイルに追記する。別の投稿先を指定されたときはそちらに従う。

**評価軸レビュー（step 5）は Slack へは投稿しない**。承認後に Notion DB（設定の `{log_db}`）へ 1 行追記するだけ。日報本体（Slack）と採点行（Notion）は 1 回の承認でまとめて確定してよい。

## 注意事項

- **投稿・記録は承認後のみ**。ドラフト（日報本体＋採点行）を提示 → ユーザーが確定 → Slack 投稿 & Notion 追記、の順を必ず守る
- いずれかの収集ステップでエラーが出ても後続は止めない（部分的な材料でドラフトを作り、欠けたソースを ⚠️ で明示）
- 当日 0 件のソースは「なし」として扱い、無理に埋めない
- `~/.claude/daily-report/` が無ければ作る。ファイルは日付単位で 1 本（宣言と日報を同居させる）
