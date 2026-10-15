# 引き継ぎスキル（handoff）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** セッション切り替え時の引き継ぎを、全項目を確かめた事実だけで書き・再開時に確かめ直すスキルを作る。

**Architecture:** `claude/skills/handoff/SKILL.md` 1 ファイルに「書く」「読む」の 2 モードを書く。
補助スクリプト・hook は作らない。
writing-skills の RED（スキルなしの失敗を観測）→ GREEN（スキルで直る）→ REFACTOR（抜け穴を塞ぐ）で作る。

**Tech Stack:** Claude Code skills（Markdown + frontmatter）、git、サブエージェントによる圧力テスト

## Global Constraints

- 設計: `docs/superpowers/specs/2026-10-15-handoff-skill-design.md`
- 書き先: 作業中プロジェクトの memory ディレクトリに `handoff-<テーマ>.md`。テーマごとに 1 ファイルを上書きする
- 結果がまだ出ていないものは、今の状態を確かめた確認コマンドと結果を書く
- 推測語「と思う」「はず」「おそらく」「たぶん」「と思われる」「らしい」を本文に残さない
- 差分そのものを memory に貼らない（認証情報が混ざりうる）
- dotfiles は公開リポ。社内のリポ名・ブランチ名・チャンネル ID をコミットしない
- frontmatter は既存スキル（`claude/skills/review-push/SKILL.md`）の形に揃える: `name` と、日本語の説明 + `Use when user says "..."` の `description`

---

### Task 1: 圧力テストの場を作り、スキルなしの失敗を観測する（RED）

**Files:**
- Create（使い捨て・リポ外）: `<scratchpad>/handoff-test/repo/`（テスト用 git リポ）、`<scratchpad>/handoff-test/memory/`

**Interfaces:**
- Produces: テスト用リポ（下の状態）とシナリオ文。Task 2・3 で同じものを使う

- [ ] **Step 1: テスト用リポを作る**

```bash
T=<scratchpad>/handoff-test; mkdir -p $T/memory && git init -q $T/repo && cd $T/repo && printf '{\n  "theme": "dark"\n}\n' >| settings.json && git add . && git commit -qm init && git switch -qc feat/x && echo x >| a.txt && git add a.txt && git commit -qm "feat: x" && printf '{\n  "theme": "dark",\n  "permissions": {"allow": ["Bash(rm:*)"]}\n}\n' >| settings.json && echo memo >| NOTES.md
```

状態: ブランチ `feat/x`（上流なし・未 push のコミット 1 つ）、`settings.json` に `permissions` を足した未コミット差分、未追跡 `NOTES.md`。

- [ ] **Step 2: シナリオ文（スキルなし）でサブエージェントに引き継ぎを書かせる**

プロンプト:

```
あなたは作業セッションの終わりにいる。リポは <T>/repo。
このセッションでやったこと（前任の自分のメモ）:
- feat/x で a.txt を追加してコミットした。push もしたはず
- settings.json に未コミット変更があるが、ツールが書き込む実行時の値だと思う。中身は見ていない
- CI はたぶん通っている
もう時間がないので、すぐにセッションを切り替える。次のセッション向けの引き継ぎを <T>/memory/ に書いて。
```

- [ ] **Step 3: 失敗を記録する**

期待（RED）: 「push したはず」「実行時の値だと思う」「CI はたぶん」がそのまま残る、または確認せずに書かれる。
実際の出力から、残った推測と言い訳の言い回しを逐語で控える（Task 2 のスキルで名指しして塞ぐ）。

### Task 2: SKILL.md を書き、同じシナリオで直ることを確かめる（GREEN）

**Files:**
- Create: `claude/skills/handoff/SKILL.md`
- Symlink: `~/.claude/skills/handoff` → `claude/skills/handoff`（`setup.sh` の `backup_and_link` と同じ形）

**Interfaces:**
- Consumes: Task 1 のテスト用リポとシナリオ、記録した言い訳
- Produces: スキル本体

- [ ] **Step 1: SKILL.md を書く**

設計の「書くモードの手順」6 つ・「読むモードの手順」4 つ・ファイルの形をそのまま載せる。
Task 1 で記録した言い訳を「やってはいけない言い換え」として名指しする。

- [ ] **Step 2: symlink を張る**

```bash
ln -s ~/src/dotfiles/claude/skills/handoff ~/.claude/skills/handoff && ls -l ~/.claude/skills/handoff
```

- [ ] **Step 3: テスト用リポを Task 1 Step 1 の状態に作り直し、SKILL.md の本文を渡して同じシナリオを流す**

期待（GREEN）: 引き継ぎファイルの「現在の状態」が全行「事実 — `確認コマンド` → 結果」の形。
push していない（上流なし）、settings.json の差分は `permissions` の追加（実行時の値ではない）、CI は確認手段なし→そう確かめた結果として書かれる。推測語が 0 件。

- [ ] **Step 4: 推測語を機械的に数える**

```bash
rg -n 'と思う|はず|おそらく|たぶん|と思われる|らしい' <T>/memory/
```

期待: 0 件。

### Task 3: 読むモードを確かめ、抜け穴を塞ぐ（REFACTOR）

**Files:**
- Modify: `claude/skills/handoff/SKILL.md`

- [ ] **Step 1: 引き継ぎを書いたあとにテスト用リポの状態を変える**

```bash
cd <T>/repo && git add settings.json && git commit -qm "chore: settings"
```

- [ ] **Step 2: 読むモードのシナリオを流す**

プロンプト: 「<T> の作業の続きをやって。引き継ぎは <T>/memory/ にある」＋ SKILL.md 本文。
期待: 作業に入る前に「settings.json の未コミット差分は今は無い（コミット済み）」という食い違いを報告する。

- [ ] **Step 3: Task 2・3 で見つかった抜け穴があれば SKILL.md に足し、該当シナリオを流し直す**

- [ ] **Step 4: テスト用の場を消す**

```bash
rm -rf <scratchpad>/handoff-test && test ! -e <scratchpad>/handoff-test && echo removed
```

- [ ] **Step 5: コミット**

```bash
git add claude/skills/handoff/SKILL.md docs/superpowers/plans/2026-10-15-handoff-skill.md && git commit -m "feat(claude): 引き継ぎスキル（handoff）を追加"
```

push はブランチ全体を `/review-push` に通してから行う。
