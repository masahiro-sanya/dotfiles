---
name: morning
description: 朝一ルーチン。Claude Code 更新 → light-skills 更新 → 全プロジェクトのセッション進捗確認 → 全リポPRレビュー状況（reviewer/reviewee 両方）→ 技術記事フィード収集 → 月次 memory 還流（月初のみ）→ 週次ハーネス健全性（週初のみ・委譲ミックス／guard発火／fail-openの点検）→ 今日の宣言（daily-report 朝モードで宣言を作り投稿）を順番に実行する。Use when user says "朝一", "morning", "/morning", "朝のルーチン", "あさいち".
allowed-tools: Bash(claude update), Bash(claude --version), Bash(cat ~/.claude/.morning-prep-last), Bash(gh search prs *), Bash(~/.claude/skills/morning/session-status.py *), Bash(~/.claude/skills/morning/agent-usage.py *), Bash(date +%G-W%V), Read, Write, Skill, Task
---

# 朝一ルーチン

毎朝最初に実行する個人ワークフロー。8 ステップ（手順 6 は月初のみ・手順 7 は週初のみ）なので **TaskCreate で進捗管理** すること。

> **委譲方針（手順 3・4・5・7・8）**: 収集・実行そのものはサブエージェントに投げ、main は判断・講評・提示・サマリだけ持つ（daily-report 夜モードと同じ型で、生ログを main の文脈に持ち込まない）。手順 3・4・7 の収集は **investigator**（read 専用・要約返し）、手順 5 のフィード収集は **feed-collector**（書き込み可）に委譲する。**冒頭で重い委譲をまとめて並列起動する（体感速度の要）**: ルーチン開始時に、独立している **手順 3（セッション調査）・手順 4（PR状況）・手順 5（feed-collector）を 1 メッセージで同時に投げる**（週初はこれに手順 7 の収集も加える＝最大 4 本）。ただし手順 5 は `~/.claude/.collect-feed-last` が今日なら朝前の launchd（collect-feed-prep）で収集済み＝バッチから外し、レポートを読むだけにする（手順 5 の事前実行チェック参照）。最重量の feed 収集を survey と重ねるのが狙い。投げたら main は待つ間に手順 1・2（更新）を進め、返ってきたものから順に処理する（手順 8 の宣言は手順 3・4 が揃ってから）。手順 8 の宣言作成は **daily-report（朝モード）** に委譲し、手順 3・4 の結果を材料として渡す（宣言ロジックを morning に持たない＝真実は daily-report 側 1 箇所）。
>
> **起動確認（必須）**: サブエージェントを投げたら（冒頭バッチは**投げた全本数について**）「収集中／実行中」と表示する前に、**起動時の返り値（agent ID）と `TaskOutput`（block:false）の生存確認で裏取り**する（TaskList は TODO 一覧＝サブエージェントは載らないので裏取りに使えない）。生存が確認できないなら放置せず投げ直すか正直に報告する。起動後も完了まで見届け、無反応が続けば TaskOutput で生存を確認する（完了済みは「No task found」＋結果は完了通知で届く＝失敗ではない。空振りのまま「実行中」と述べない）。

## 手順

> **launchd 事前実行チェック**: まず `cat ~/.claude/.morning-prep-last` を確認し、**今日の日付なら手順 1・2 は launchd（morning-prep）実行済みとして skip** する（サマリには「launchd 実行済み」と記す）。日付が古い・ファイルが無い場合は通常どおり実行する。

### 1. Claude Code 本体を更新

```
claude --version    # 旧バージョン記録
claude update
claude --version    # 新バージョン確認
```

更新があれば「`/clear` またはセッション再起動で反映」と案内。

### 2. light-skills プラグインを更新

Skill ツールで `light-skills-updater:update-plugins` を起動。結果はそのまま表示する。

### 3. 全プロジェクトのセッション進捗確認

**investigator に委譲**する（72h 分の生ログで main の文脈を汚さないため）。手順 4・5（週初は 7 の収集も）と独立なので、冒頭バッチで 1 メッセージにまとめて同時に投げる。

investigator への指示: `~/.claude/skills/morning/session-status.py 72` を実行し、直近72時間以内に触ったプロジェクト別に、各セッションが **どこで止まっているか**（最終アクティビティ時刻・最後のユーザー発話＝何を頼んでいたか・最後のアシスタント発話＝どこで終わったか・stopReason）を要約する。特に次を抽出して **構造化要約** で返させる（生の72h出力は貼らせない）:

- 明らかに **判断待ちで止まっているもの**（「許可待ち」「確認お願いします」等）
- 「次に行うのは＞」「進め方これで良いかな」のような **未完了の問いかけが残っているもの**

このステップは **「昨日までの未完タスクの棚卸し」** が目的。main は返ってきた要約を提示し、再開候補 2-3 個への短い観点付けをして、**ユーザーに「今日どれを再開する？」と聞く**（この判断・問いかけは main が持つ）。

### 4. 全リポジトリのPRレビュー状況

**investigator に委譲**する（手順 3・5 と独立なので冒頭バッチで同時に投げる）。investigator への指示: **自分がレビュワー** と **自分がオーナー** の両方のオープン PR を下記2クエリで取得し、下の表示フォーマットに整形して **URL 付きで返す**。

```bash
# 自分がレビュワーに指定されている open PR（レビュー待ち）
gh search prs --review-requested=@me --state=open --json url,title,author,repository,updatedAt,isDraft \
  --limit 50

# 自分が author の open PR（自分のPR）
gh search prs --author=@me --state=open --json url,title,reviewDecision,repository,updatedAt,isDraft \
  --limit 50
```

- スコープは light-inc / light-inc-sub / palmu 系を含む。`--owner` で絞らずグローバル検索で良い
- Draft PR は `[Draft]` を末尾に付ける
- 古い順（updatedAt 古い → 新しい）でソート、滞留しているものを上に
- 0件のセクションは「なし ✅」と表示

**表示フォーマット**:

```
### レビュー待ち（自分が reviewer）
- [リポ名] PR#番号 タイトル — author / 最終更新N日前 [Draft]
  URL

### 自分のPR（自分が author）
- [リポ名] PR#番号 タイトル — レビュー状況（APPROVED/CHANGES_REQUESTED/REVIEW_REQUIRED）/ N日前 [Draft]
  URL
```

main は返ってきた整形済みリストをそのまま提示し、サマリに件数を出す。

### 5. 技術記事フィード収集

> **launchd 事前実行チェック**: まず `~/.claude/.collect-feed-last` を Read し、**今日の日付なら朝前の launchd（collect-feed-prep）が収集済み**。feed-collector は起動せず、`~/.claude/collect-feed-report.md` を Read してそのレポートを提示する（headless の main セッションで Workflow 並列巡回が使えるため、対話セッション側は読むだけで済む。サマリには登録件数と「launchd 実行済み」を記す）。スタンプが今日でない場合も、`~/.claude/collect-feed-prep.log` の末尾を Read し、**今日の start があって完了記録が無ければ launchd 収集が進行中**（8:15 開始で 1 時間半ほどかかる）＝feed-collector を起動しない（二重収集の防止）。手順 5 は「launchd 収集中（レポートは完了後に確認）」としてサマリに記す。スタンプもログも今日でない（＝ジョブが落ちた・走らなかった）場合のみ、以下の feed-collector 委譲を実行する。

**feed-collector に委譲**する（config 読み・Notion クエリ・巡回ログで main の文脈を汚さないため）。**朝で最重量の手順なので、手順 3・4 と一緒に冒頭バッチで同時起動する**（survey と重ねて待ち時間を隠す）。feed-collector は `collect-feed:collect-feed` を最後まで回し（古い記事のアーカイブ・Notion 登録・🚨時の Slack 通知・light-inc 横断調査まで）、**Step 10 の収集レポートだけ**を返す。main はそのレポートを提示し、サマリに Notion 登録件数を出す。

- **20〜30 分かかるのが正常・遅くても kill しない**: サブエージェント内では `Workflow` が使えず、約50ソースを単独直列で WebFetch＋途中で自動コンテキスト圧縮が数回走るため、この手順は元々20〜30分かかる。無反応に見えても、まず `TaskOutput`（block:false）等で **進捗を確認** し、能動的に tool を叩いていれば正常＝待つ。**前進しているジョブを止めない**（過去に前進中の feed を kill して 27 分の仕事を 65 分に伸ばした）。
- **最終サマリを feed で待たない（ブロックしない）**: 手順 8 の宣言は 手順 3・4 だけで組めて feed に依存しないので、**手順 1-4・6-8 が終わっても feed がまだ収集中なら、手順 5 を「収集中（縮退モード・完了後に別途報告）」としてサマリを先に出してよい**。feed-collector が完了したらそのレポートを追記する。feed 待ちで朝ルーチン全体を止めない。
- **フォールバック**: feed-collector が収集を完了できない（単独直列の順次巡回にも失敗した）場合に限り、main が従来どおり Skill ツールで `collect-feed:collect-feed` を直接実行する（**main なら `Workflow` が使えて並列巡回が復活する＝速い**。他手順の委譲はそのまま）。

### 6. 月次 memory 還流（月初のみ）

その月の最初の /morning でだけ実施する。月次判定と実施手順は同ディレクトリの `memory-reflow.md` を **Read して従う**。月初でない（今月実施済み）ならスキップし、サマリにその旨を出す。

### 7. 週次ハーネス健全性（週初のみ）

その週の最初の /morning でだけ実施する。`~/.claude/.morning-harness-health-last` を Read し、中身が今週（`date +%G-W%V` の値、例 `2026-W28`）と一致したらスキップ（サマリに「今週実施済み」）。異なる・ファイルが無いなら実施し、**完了後に今週の値を Write する**。

ハーネスが実際に効いているかを週1で点検する。**ここは点検が目的で、見つけた改善はその場で書き換えず、必要なら別途 feature branch で対応する。**

**収集は investigator に委譲**する（手順 3・4 と独立なので、週初はこの収集も同じ並列バッチに乗せてよい）。investigator への指示: 下記3点を実行・集計し、**要約**で返す（生ログは貼らせない）。

1. `~/.claude/skills/morning/agent-usage.py 7` を実行し、直近7日の Task 委譲を **subagent_type 別に集計** する。
2. `~/.claude/guard-hits.log`（あれば）を Read し、**reason 別に発火件数を集計** する（無ければ「発火なし」）。
3. `~/.claude/hooks-error.log`（あれば）を Read し、**直近1週間の fail-open 記録**（どの hook のどのパースが落ちたか）を抽出する（無ければ「fail-open なし」）。`jq parse failed` の行には真因特定用の診断（`bytes=`＝入力バイト数、`jqerr=`＝パースエラー位置）が付いているので、再発があればその値も併せて報告する（入力が途中で切れているのか・壊れた JSON なのかを切り分ける材料になる）。

main は返ってきた要約に **講評・判定を付ける**（この判断は main が持つ）:
- **委譲の偏り**: **general-purpose に寄りすぎていないか**（例: 「調査・検証は investigator / verify-runner に寄せられたはず」）。自作エージェントへ委譲が移っているかの定点観測。
- **guard の発火**: **誤爆に見える発火**（正当な操作をブロックした形跡）は「このガードは誤爆、緩めるか要検討」、**ずっと発火ゼロのガード**は「出番がないだけか死んでいるか要確認」と添える。
- **fail-open インシデント**: 記録があるということは入力異常などで **ガードが exit 0（許可）に倒れた＝その瞬間ガードが実質無効だった** ことを意味する。恒常的に出ているなら hook 側の修正を別 branch で検討する。guard-hits（発火）と対で、こちらは無効化の可視化。

### 8. 今日の宣言（daily-report 朝モードへ委譲）

その日のタスクと目標を宣言する。**宣言の作成は `daily-report` スキルに委譲する**（宣言ロジックの真実は daily-report 側 1 箇所に置き、morning では組み立てない）。

Skill ツールで `daily-report` を **朝モード**で起動し、次を伝えて材料を渡す:

- 「morning から連携。**今日のセッション調査と自分のオープン PR は取得済みなので再取得は不要**」
- 手順 3 で investigator がまとめた **セッション調査の要約**（どのタスクがどこで止まっているか）
- 手順 4 で取得した **自分のオープン PR 一覧**（`gh search prs --author=@me` 相当の分）

daily-report 側が前日ファイルの「明日やること」＋前日採点を読み合わせ、これらを材料に今日の宣言ドラフトを作る。以降はドラフト提示 → ユーザー承認 → **#daily-sanya 投稿**まで daily-report の標準フローに従う（morning はその結果を最終サマリに載せるだけ）。

- daily-report が使えない・eval-config 未設定などは daily-report 側で ⚠️ 縮退する（morning は止めない・完走優先）。
- 宣言まで作らない日は、ユーザーが承認ゲートで見送ればよい（サマリには「見送り」と記す）。

## 最終サマリ

全ステップ完了後、以下を出す：

```
朝一ルーチン完了 ☀️

1. Claude Code: <旧> → <新>（または "更新なし"）
2. light-skills: <N> 件更新
3. セッション: <N> プロジェクトで進行中（要再開: <候補2-3個>）
4. PR: レビュー待ち <N> 件 / 自分のPR <N> 件
5. collect-feed: <N> 件 Notion 登録
6. memory還流: 提案 <N> 件（採用 <M> 件）（または "今月実施済み" / "月初でないためスキップ"）
7. ハーネス健全性: 委譲 general-purpose <N> / 自作 <M>・guard発火 <K> 件・fail-open <L> 件（または "今週実施済み" / "週初でないためスキップ"）
8. 宣言: 投稿済み / ドラフト提示（または "見送り"）
```

## 注意事項

- いずれかのステップでエラーが出ても **後続は止めない**（朝一は完走優先）
- エラーがあったステップは最終サマリに `⚠️` を付けて明示
- TaskCreate で全ステップを管理し、in_progress → completed を逐次更新
- 手順 6 は提案と承認が本体。**承認なしで CLAUDE.md やスキルを書き換えない**
