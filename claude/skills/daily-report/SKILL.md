---
name: daily-report
description: 日報作成。当日の作業実績（コミット・PR 活動・Claude セッション・memory 更新）を横断収集し、アウトカム中心の日報ドラフトを作る。投稿は承認後のみ。Use when user says "日報", "daily report", "/daily-report", "今日のまとめ".
allowed-tools: Bash(git -C *), Bash(gh search prs *), Bash(gh pr list *), Bash(fd *), Bash(jq *), Bash(head *), Bash(date), Read
---

# 日報作成

当日の作業を **アウトカム（何がどこまで進み、何に効くか）** で語る日報を作る個人ワークフロー。
背景: 作業の可視化ギャップを潰すのが目的。作業ログの羅列ではなく「成果・進捗・ブロッカー」に翻訳する。

4 ステップなので **TaskCreate で進捗管理** すること。

## 手順

### 1. 当日のコミットを横断収集

~/src 配下の git リポを列挙し、当日分の自分のコミットを集める:

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

### 4. 日報ドラフトを組み立てる

収集結果を **#daily-sanya の退勤報告テンプレに合わせて翻訳** する（コミットメッセージの転記ではなく、成果の言葉にする）:

```
■今日のタスク
• <やったこと。「何がどこまで進み、何が使える/直った状態になったか」で書く。PR リンク付き>
    ◦ <サブ項目>

■振り返り
• <アウトカムと予定比を 1-3 行。例: 予定どおり / 1日遅れ・理由は X。git/PR に残らない調査・設計・運用対応もここで拾う>

■次回やること
• <優先順に 2-3 個>

■その他
• <ブロッカー・相談・共有。なければ省略可>
```

- 「■振り返り」を空欄にしない。ここが可視化ギャップ解消の本丸（最低でも予定比 1 行）
- タスク欄は前日のコピーにしない。同じ案件でも「今日進んだ差分」を書く
- 成果が多い日は重要な 3-5 個に絞る（全部書かない）
- 秘匿情報（API キー・顧客データ・未公開の人事情報）は書かない

## 投稿先

**#daily-sanya**（Slack、C04CBF2JWAD）。打刻（退勤報告）と日報が一体化したチャンネル。

- 基本フローは **貼り付け用ドラフトの提示**: ユーザーが退勤打刻フォームにそのまま貼れるテンプレ形式で出す
- ユーザーが「投稿して」と言った場合のみ、承認済み文面を #daily-sanya へ通常メッセージとして投稿する（打刻とは別メッセージになる旨を一言添える）

## 注意事項

- **投稿は承認後のみ**。ドラフトを提示 → ユーザーが文面を確定 → 指定先へ投稿、の順を必ず守る
- いずれかの収集ステップでエラーが出ても後続は止めない（部分的な材料でドラフトを作り、欠けたソースを ⚠️ で明示）
- 当日 0 件のソースは「なし」として扱い、無理に埋めない
