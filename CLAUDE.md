# dotfiles リポの作業ルール

macOS 環境設定リポ。`setup.sh` が各設定を `$HOME` 配下へ symlink する
（例: `~/.claude/settings.json` → `claude/settings.json`、hooks は1本ずつ、skills はディレクトリごと）。
**リポ側ファイルの編集は symlink 経由で即座にライブ環境へ反映される**前提で作業する。

## claude/settings.json

- `model` / `tui` / `skipWorkflowUsageWarning` / `agentPushNotifEnabled` は Claude Code が書き込む実行時フィールド。**絶対にコミットしない**（diff に混入していたら除去してからコミット）
- コミット前に `jq . claude/settings.json` で JSON 妥当性を確認する

## claude/hooks/

- 変更したら必ず `bash -n <script>` と `bash claude/hooks/tests/run-tests.sh` を実行する
- macOS 標準の bash 3.2 互換で書く。変数展開は `${var}` 形式に統一（bash 3.2 は `$var` 直後の全角文字で変数名解釈が壊れる）
- fail-open 設計: 入力異常では exit 0 で許可に倒す。ただし `~/.claude/hooks-error.log` に痕跡を残す

## シェル操作の注意

- この環境の `rm` は `-i` エイリアス。非対話実行では削除されないまま exit 0 になるため **`command rm -f` を使い、削除後に ls で裏取りする**
- zsh は noclobber 設定。上書きリダイレクトは `>|` を使う
