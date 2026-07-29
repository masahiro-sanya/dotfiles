# codex/

Codex CLI（`~/.codex`）のうち dotfiles で管理する設定。

## hooks.json

Codex の稼働状態を WezTerm タブに出すための hooks 定義。
`~/.codex/hooks.json` へ symlink する（`setup.sh` が配線）。

- Claude 用の `claude/hooks/wezterm-status.sh` を **そのまま** 使い回す。
- 呼び出し時に `WEZTERM_STATUS_AGENT=codex` を渡すと、状態ファイル
  `~/.claude/wezterm-state/pane-<pane>` の中身に `codex:` が前置される。
- `terminal/wezterm/wezterm.lua` がそのプレフィックスを見て、Codex を
  専用色（teal 系）＋ `ᶜ` バッジで表示する（Claude は無印のまま）。
- 表示は busy / idle / waiting の3状態のみ。サブエージェント数は出さない。

イベント対応:

| Codex event       | 表示     |
|-------------------|----------|
| SessionStart      | idle     |
| UserPromptSubmit  | busy     |
| PreToolUse        | busy     |
| PostToolUse       | busy     |
| PermissionRequest | waiting  |
| Stop              | idle     |

Claude と Codex は 1 ペイン内で同時に前面には出ない（1 ペイン = 1 前面プロセス）ため、
`main-<pane>` / marker のファイル名は両者で共有してよい。別ペインなら別ファイルで独立する。
タブ集約は「要対応 > サブ稼働 > 実行中 > 待機中」で、同順位に Claude と Codex が混在するときは
Codex を優先して見せる。

## 反映のしかた（重要: trust が要る）

Codex は hooks をハッシュで trust する仕組みなので、`hooks.json` を置く/変えるだけでは走らない。

1. `setup.sh` で `~/.codex/hooks.json` を symlink（または既に symlink 済み）。
2. Codex を起動し、`/hooks` で新しい hook を **trust** する。
3. Codex が `~/.codex/hooks.json` を自動読込しない環境では、`~/.codex/config.toml` の
   トップレベルに `hooks = "hooks.json"` を追加する（`[projects]` などのセクションより前に置くこと）。

`config.toml` は Codex がランタイム値（モデルの NUX カウンタ等）を書き込むため dotfiles では管理しない。
