#!/usr/bin/env bash
# Claude Code Stop hook — ターン完了の音（herdr の外だけ）
#
# 通知の持ち主は herdr（~/.config/herdr/config.toml の [ui.sound]。背景ワークスペースだけ
# 鳴る。[ui.toast] は delivery = "off" にしてあり、ポップアップは出さない）。
# herdr のペイン内では鳴らさない:
# hook は自分がフォアグラウンドかを知らないので、鳴らす役をここに残すと必ず二重になる。
# 素の WezTerm で回すときは herdr が居ないので、この hook が完了音を担う。
#
# bell(\a) と OSC 2 のタブバッジを使わない理由（どちらも実測で no-op だった）:
#  - hook の子プロセスは制御端末を持たず、stdout も Claude Code が拾うので端末に届かない
#    （wezterm-status.sh の冒頭コメントに同じ実測がある）。
#  - タブ表示は wezterm.lua が cwd のリポ名 + 状態ファイルから組み立てる。pane title は
#    cwd が取れないときのフォールバックでしかない。
# タブへの反映が要るなら wezterm-status.sh（状態ファイル）側に足すこと。
#
# herdr 判定は wezterm-status.sh と同じ `= "1"` に揃える（片方が「herdr 内」、もう片方が
# 「herdr 外」と判断する食い違いを作らない）。
#
# テスト用フック(env で差し替え):
#  - CLAUDE_STOP_SOUND : 鳴らす音声ファイル（既定 /System/Library/Sounds/Glass.aiff）

set -u

[ "${HERDR_ENV:-}" = "1" ] && exit 0

SOUND="${CLAUDE_STOP_SOUND:-/System/Library/Sounds/Glass.aiff}"
if command -v afplay >/dev/null 2>&1 && [ -r "${SOUND}" ]; then
  afplay "${SOUND}" >/dev/null 2>&1 &
fi

exit 0
