---
name: daily-report
description: 日報サイクル。朝は「今日のタスクと目標」を宣言、夜は当日の作業実績（コミット・PR 活動・Claude セッション・memory 更新）を横断収集して朝の宣言と突き合わせ、アウトカム中心の日報を作る。投稿は承認後のみ。Use when user says "日報", "daily report", "/daily-report", "今日のまとめ", "今日やること".
allowed-tools: Bash(git -C *), Bash(gh search prs *), Bash(gh pr list *), Bash(fd *), Bash(jq *), Bash(head *), Bash(cat *), Bash(date), Read, Write, mcp__plugin_slack_slack__slack_send_message
---

# 日報サイクル

**朝に宣言 → 夜に宣言と突き合わせて振り返る** 個人ワークフロー。
背景: 作業の可視化ギャップを潰すのが目的。作業ログの羅列ではなく「宣言に対して何がどこまで進んだか」に翻訳する。

宣言と日報は `~/.claude/daily-report/YYYY-MM-DD.md` に保存し、夜の突き合わせと翌朝の引き継ぎに使う。

## モード判定

- 「今日やること」「日報 朝」など**開始時** → 朝モード（宣言）
- 「日報」「今日のまとめ」など**終了時** → 夜モード(振り返り)。当日ファイルに宣言が無ければ「宣言なし」として進める（催促しない）

## 朝モード: 今日のタスクと目標を宣言する

材料を集めて「今日のタスク内容と目標」を作る:

1. 前日（直近）の `~/.claude/daily-report/*.md` の「明日やること」を読む
2. 自分のオープン PR を確認: `gh search prs --author=@me --state=open --json url,title,repository,updatedAt --limit 30`
3. ユーザーと 1-2 往復で確定し、当日ファイルに保存する:

```
## 宣言 YYYY-MM-DD

- <タスク>: <今日どこまで進めるか（目標を測れる形で。例: 設計レビュー依頼まで / PR マージまで）>
- ...
```

目標は「やる」でなく **「どこまで行ったら達成か」** が分かる形で書く（夜の予定比の基準になる）。

## 夜モード: 収集して振り返る

### 1. 当日のコミットを横断収集

```bash
today=$(date +%F)
for d in $(fd -H -t d '^\.git$' ~/src --max-depth 4 -x dirname {} | sort -u); do
  log=$(git -C "${d}" log --all --since="${today} 00:00" --author="$(git -C "${d}" config user.email)" --oneline 2>/dev/null)
  [ -n "${log}" ] && printf '## %s\n%s\n' "${d}" "${log}"
done
```

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

### 3. 当日の Claude セッションと memory 更新を確認

```bash
# 当日触ったプロジェクトとプロンプト概要（スキーマは実物を head で確認してから jq を書く）
head -1 ~/.claude/history.jsonl
jq -r 'select(.timestamp != null)' ~/.claude/history.jsonl | tail -50   # 当日分に絞って集計
# 今日更新された memory（進行中タスクの根拠になる）
fd . ~/.claude/projects --glob '*.md' --changed-within 1d
```

git/PR に現れない作業（調査・設計・レビュー・運用対応）をここで拾う。これが可視化ギャップの本丸。

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

完成したら当日ファイルに追記保存し、ドラフトをユーザーに提示する。

## 投稿

宣言（朝）・日報（夜）とも、ユーザーが文面を承認したら **#daily-sanya (C04CBF2JWAD) へ投稿するまでが標準フロー**。投稿後はメッセージリンクを当日ファイルに追記する。別の投稿先を指定されたときはそちらに従う。

## 注意事項

- **投稿は承認後のみ**。ドラフトを提示 → ユーザーが文面を確定 → 指定先へ投稿、の順を必ず守る
- いずれかの収集ステップでエラーが出ても後続は止めない（部分的な材料でドラフトを作り、欠けたソースを ⚠️ で明示）
- 当日 0 件のソースは「なし」として扱い、無理に埋めない
- `~/.claude/daily-report/` が無ければ作る。ファイルは日付単位で 1 本（宣言と日報を同居させる）
