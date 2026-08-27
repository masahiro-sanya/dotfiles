# dotfiles リポの作業ルール

macOS 環境設定リポ。`setup.sh` が各設定を `$HOME` 配下へ symlink する
（例: `~/.claude/settings.json` → `claude/settings.json`、hooks は1本ずつ、skills はディレクトリごと）。
**リポ側ファイルの編集は symlink 経由で即座にライブ環境へ反映される**前提で作業する。

## claude/settings.json

- `model` / `effortLevel` / `tui` / `skipWorkflowUsageWarning` / `agentPushNotifEnabled` / `skipDangerousModePermissionPrompt` / `autoMode` は Claude Code が書き込む実行時フィールド。**絶対にコミットしない**（`autoMode` は作業中のリポの GCP プロジェクト名・バケット名・内部ドメイン・private リポ名を溜め込む。ここは公開リポなので特に危ない）
- 除去は `setup.sh` が登録する git clean filter が自動で行う（index からだけ除去し、ライブ設定は無傷）。キー一覧の定義元は `git/strip-claude-runtime.sh` の `RUNTIME_KEYS` ただ1つで、pre-commit / CI は `--check` を呼ぶだけ。**consumer 側にキー一覧を書き足さない**（食い違うと commit が詰まる）
- pre-commit にランタイムフィールドで止められたら、filter 未登録を疑う（`git config --get filter.strip-claude-runtime.clean` が空なら `setup.sh` を実行）
- コミット前に `jq . claude/settings.json` で JSON 妥当性を確認する
- `alwaysThinkingEnabled: false`（トークン節約のため thinking を切っている）は **effort 指定と衝突しうる**。モデルによっては API が 400 `effort 'X' is not supported when thinking is disabled` を返し、CLI は `remove "alwaysThinkingEnabled": false from settings` と案内する。このエラーが出たら effort を下げるのではなく**このキーを消す**（＝thinking を戻す）のが正解。UI の Thinking トグルを ON にしても同じ（トグルは false を書くか、キー自体を消すかの 2 状態）
- SessionStart の `herdr-agent-state.sh` を呼ぶエントリ（`codex/hooks.json` 側も同じ）は **herdr が自分で注入・上書きする外部所有の配線**。JSON なのでファイルに印を置けないためここに書く。`herdr update` や再インストールのあとは `git diff` を見て、二重注入や身に覚えのない再整形が入っていないか確かめる

## マシン固有の絶対パス

- このリポは複数の Mac で共有する。ユーザー名も dotfiles の置き場もマシンごとに違うので、**設定・スクリプトに `/Users/<name>/...` を直書きしない**（別マシンで無言で壊れる。CI が検知して落とす）
- Claude Code の hook コマンドはシェル経由なので `~/.claude/...` と書く。リポに無いライブ専用スクリプトを呼ぶときは `if [ -x ~/path ]; then ~/path; fi` の形にして、未配置のマシンでは no-op にする
- launchd の plist は `~` を展開しないため symlink できない。`launchd/*.plist.template` に `__HOME__` / `__DOTFILES_DIR__` を置き、`setup.sh` が実パスを埋めて `~/Library/LaunchAgents/` へ生成する（内容が変わったときだけ bootout → bootstrap）

## claude/hooks/

- 変更したら必ず `bash -n <script>` と `bash claude/hooks/tests/run-tests.sh` を実行する
- macOS 標準の bash 3.2 互換で書く。変数展開は `${var}` 形式に統一（bash 3.2 は `$var` 直後の全角文字で変数名解釈が壊れる）
- fail-open 設計: 入力異常では exit 0 で許可に倒す。ただし `~/.claude/hooks-error.log` に痕跡を残す
- hook に手で JSON を流して動作確認するときは `GUARD_HITS_LOG=$(mktemp)`（必要に応じ `HOOKS_ERROR_LOG` も）を付け、本物のテレメトリを汚さない（run-tests.sh は退避済みだが、単発の手動実行は素通しで実ログに混ざる。2026-07-31 に実例あり）

## git worktree

- worktree を使うのはマージ・cherry-pick 等の git 操作に限る。`$HOME` 配下の symlink は主チェックアウトの絶対パスを指すため、**worktree 側でファイルを編集してもライブ環境には反映されない**
- worktree はこのリポの中に作らない（`setup.sh` の symlink 対象や未追跡ファイルと混ざる）。用が済んだら `git worktree remove <path>` → `git worktree prune` → `git worktree list` で消えたことを確認する

## シェル操作の注意

- この環境の `rm` は `-i` エイリアス。非対話実行では削除されないまま exit 0 になるため **`command rm -f` を使い、削除後に ls で裏取りする**
- zsh は noclobber 設定。上書きリダイレクトは `>|` を使う
