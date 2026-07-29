# 月次 memory 還流（/morning 手順6の詳細）

memory に溜まった知見を「読むだけの記録」から「毎回効く仕組み（CLAUDE.md / hook / スキル）」へ焼き込むステップ。**その月の最初の /morning 実行時だけ** 行う。

## 月次判定

`~/.claude/.morning-memory-reflow-last` を Read し、中身が今月（`YYYY-MM`）と一致したらこのステップはスキップ（サマリに「今月実施済み」と表示）。ファイルが無い・先月以前なら実施し、完了後に今月の `YYYY-MM` を Write する。

## 実施内容

1. **全プロジェクトの memory 横断読み取りと棚卸し候補の抽出を investigator に委譲する**（`~/.claude/projects` 配下は量が多く main の文脈を汚すため）。investigator への指示:
   - `fd MEMORY.md ~/.claude/projects --max-depth 3` で全索引を集め、各 `MEMORY.md`（索引で足りなければ個別ファイルも）を Read し、次の観点で候補を要約して返す:
     - **昇格候補**: 複数プロジェクトに繰り返し出てくる失敗知見・feedback → グローバル CLAUDE.md（`~/src/dotfiles/claude/CLAUDE.md`）への追記、または PreToolUse hook / スキルへの機械化
     - **負債候補**: 古くなった・実態と矛盾する memory → 更新 or 削除
   - 返すのは「対象 memory / 内容 / 昇格先 / 理由」の候補一覧（生の全文でなく要約）
2. investigator が返した候補一覧を main がユーザーに見せ、**承認されたものだけ** 適用する。dotfiles 側の変更（CLAUDE.md / hooks）は feature branch を切って PR にする
3. 候補ゼロなら「還流対象なし」でよい。無理に何か作らない

## 注意

- 提案と承認が本体。**承認なしで CLAUDE.md やスキルを書き換えない**
