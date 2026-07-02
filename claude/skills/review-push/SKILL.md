---
name: review-push
description: ローカルレビューを指摘ゼロまで収束させてから commit / push する個人ワークフロー。code-review --fix を反復し、通過した HEAD を記録して push する。レビューゲート付きリポ（.claude-review-gate）では push 前に必須。Use when user says "/review-push", "レビューしてpush", "レビュー通してプッシュ", "レビュー通ったらpush", "review push".
---

# review-push: ローカルレビュー収束 → commit → push

push する前にローカルでレビューを回し、指摘がゼロになった状態だけを外に出すための個人ワークフロー。`.claude-review-gate` があるリポでは PreToolUse hook（`guard-review-push.sh`）がこのスキルの通過記録なしの push をブロックする。

## 手順

### 1. 対象差分の確認

```bash
git status --short
git log --oneline @{upstream}..HEAD 2>/dev/null || git log --oneline origin/HEAD..HEAD
```

未コミットの変更 + 未 push のコミットがレビュー対象。差分ゼロなら「push するものがない」で終了。
feature branch であることを確認する（main 直コミット禁止）。

### 2. レビュー収束ループ（最大 3 回）

1. Skill ツールで `code-review` を `--fix` 付きで実行し、指摘の修正まで適用させる
   - レビュー観点にはこのスキルと同じディレクトリの `checklist.md`（汎用レビューチェックリスト）を必ず含める。差分に該当する観点だけ適用し、プロジェクト固有の規約・チェックリストがあればそちらを優先して併用する
2. 修正が入ったら、プロジェクトのビルド/テストを実行して壊れていないことを確認する
   （Makefile / package.json / go.mod 等からプロジェクト標準のコマンドを判断。テストの無効化・スキップは禁止）
3. 指摘ゼロになったらループを抜ける
4. 3 回で収束しない場合は**停止してユーザーに報告**する（発散。残った指摘の一覧と、どう振動しているかを添える）

### 3. commit

修正を意味のある単位で commit する。レビューと無関係な既存の未コミット変更（実行時設定など）は混ぜない。

### 4. 通過記録

```bash
git rev-parse HEAD > "$(git rev-parse --absolute-git-dir)/claude-reviewed-sha"
```

**この記録は「いまの HEAD がレビュー通過済み」の証明。** 記録後に何かコミットしたら hook に止められるので手順 2 からやり直す。

### 5. push

```bash
git push
```

## リポでゲートを有効化するには

リポジトリの root に空ファイルを置くだけ（グローバル gitignore 済みなのでコミットには入らない）:

```bash
touch .claude-review-gate
```

## 注意事項

- ゲートが検査するのは **Claude Code が実行する git push だけ**。ユーザーが自分のターミナルから push する分には関与しない
- 緊急バイパスは**ユーザーが明示的に承認した場合のみ** `CLAUDE_REVIEW_BYPASS=1 git push`。Claude の判断で勝手に使わない
- ゲートなしのリポでもこのスキル自体は実行できる（記録は残るが push は自由）
