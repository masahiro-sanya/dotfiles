---
name: morning
description: 朝一ルーチン。Claude Code 更新 → light-skills 更新 → 全プロジェクトのセッション進捗確認 → 全リポPRレビュー状況（reviewer/reviewee 両方）→ 技術記事フィード収集 → 月次 memory 還流（月初のみ）を順番に実行する。Use when user says "朝一", "morning", "/morning", "朝のルーチン", "あさいち".
allowed-tools: Bash(claude update), Bash(claude --version), Bash(gh search prs *), Bash(gh pr list *), Bash(~/.claude/skills/morning/session-status.py *), Skill
---

# 朝一ルーチン

毎朝最初に実行する個人ワークフロー。6 ステップ（手順 6 は月初のみ）なので **TaskCreate で進捗管理** すること。

## 手順

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

```bash
~/.claude/skills/morning/session-status.py 72
```

直近72時間以内に触ったプロジェクト別に、各セッションが **どこで止まっているか** を一覧表示する。

表示内容（プロジェクト単位）:
- 最終アクティビティ時刻
- 最後のユーザー発話（何を頼んでいたか）
- 最後のアシスタント発話（どこで終わったか）
- stopReason（ある場合）

このステップは **「昨日までの未完タスクの棚卸し」** が目的。出力をユーザーに見せたあと、Claude 側で次のような観点を 1-2 行で添える：

- 明らかに **判断待ちで止まっているもの**（「許可待ち」「確認お願いします」等）を抽出
- 「次に行うのは＞」「進め方これで良いかな」みたいな未完了の問いかけが残っているもの
- ユーザーに「今日どれを再開する？」と聞く

### 4. 全リポジトリのPRレビュー状況

GitHub 上で **自分がレビュワー** と **自分がオーナー** の両方のオープン PR を取得：

```bash
# 自分がレビュワーに指定されている open PR（レビュー待ち）
gh search prs --review-requested=@me --state=open --json url,title,author,repository,updatedAt,isDraft \
  --limit 50

# 自分が author の open PR（自分のPR）
gh search prs --author=@me --state=open --json url,title,reviewDecision,repository,updatedAt,isDraft \
  --limit 50
```

スコープは light-inc / light-inc-sub / palmu 系を含む。`--owner` で絞らずグローバル検索で良い。

**表示フォーマット**:

```
### レビュー待ち（自分が reviewer）
- [リポ名] PR#番号 タイトル — author / 最終更新N日前 [Draft]
  URL

### 自分のPR（自分が author）
- [リポ名] PR#番号 タイトル — レビュー状況（APPROVED/CHANGES_REQUESTED/REVIEW_REQUIRED）/ N日前 [Draft]
  URL
```

- Draft PR は `[Draft]` を末尾に付ける
- 古い順（updatedAt 古い → 新しい）でソート、滞留しているものを上に
- 0件のセクションは「なし ✅」と表示

### 5. 技術記事フィード収集

Skill ツールで `collect-feed:collect-feed` を起動。引数なし。

### 6. 月次 memory 還流（月初のみ）

その月の最初の /morning でだけ実施する。月次判定と実施手順は同ディレクトリの `memory-reflow.md` を **Read して従う**。月初でない（今月実施済み）ならスキップし、サマリにその旨を出す。

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
```

## 注意事項

- いずれかのステップでエラーが出ても **後続は止めない**（朝一は完走優先）
- エラーがあったステップは最終サマリに `⚠️` を付けて明示
- TaskCreate で全ステップを管理し、in_progress → completed を逐次更新
- 手順 6 は提案と承認が本体。**承認なしで CLAUDE.md やスキルを書き換えない**
