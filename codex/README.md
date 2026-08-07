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

## PreToolUse のガード（Claude と共用）

対人送信ガードなど、Claude 側と同じスクリプトを `matcher` 付きで登録している。
Codex は hook へ渡すペイロードを Claude 互換の形に正規化するので、スクリプトは無改造で使える。

実測（`codex exec` に採取用フックを仕込んで確認）:

- `tool_name` は `Bash` と `apply_patch` の2つだけ。モデル向けの `exec_command` / `shell` は
  hook に届く時点で `Bash` へ正規化され、コマンドは `tool_input.command` に**文字列**で入る
  （rollout ログに出る `{"cmd": "..."}` はモデル向けのツール定義であって hook のペイロードではない）
- Codex に `Read` / `Edit` / `Write` / `WebFetch` に相当するツールは無い。ファイル読み取りも Bash 経由で、
  編集は `apply_patch`（`tool_input.command` にパッチ本文が入る）

登録しているもの:

| matcher | hook | 効果 |
|---|---|---|
| `Bash` | `guard-outbound-comms.sh` | 対人送信（GitHub コメント・Slack メンション/DM 等）をブロック |
| `Bash` | `guard-bash-command.sh` | grep/find・`--no-verify`・main 直コミットをブロック |
| `Bash` | `guard-review-push.sh` | レビューゲート未通過の push をブロック |
| `mcp__.*(slack\|notion).*` | `guard-outbound-comms.sh` | MCP 経由の対人送信をブロック（Codex 側に MCP 未設定のため現状は空振り） |

順序は Claude 側（`claude/settings.json` の Bash グループ）と揃えてある。

`guard-review-push.sh` の通過記録（`.git/claude-reviewed-sha`）を書くのは Claude の `/review-push` スキルで、
Codex 側に相当するものは無い。`.claude-review-gate` を置いたリポでは、Codex 単独の push は常にブロックされる
（レビューは Claude 側で通す前提。意図的な制約）。

Claude 側にあって**移せていない**もの（移すには改修が要る）:

- `bash-guard.sh` / `self-app-guard.sh` / `credential-guard.sh` / `webfetch-guard.sh` —
  いずれも `permissionDecision: "ask"` を返す実装だが、Codex は ask を受け付けない
  （`PreToolUse hook returned unsupported permissionDecision:ask`）。exit 2 化が要る。
  とくに `bash-guard.sh` は allowlist に加えて exfil-guard（秘密の持ち出し防止）を含むので、
  現状 Codex にはデータ持ち出しのガードが無い
- `guard-test-skip.sh` — matcher が `Edit|Write|MultiEdit` で、`tool_input.file_path` を読む。
  Codex の編集は `apply_patch` でペイロードの形が違うため、そのままでは効かない

## 反映のしかた（重要: trust が要る）

Codex は hooks をハッシュで trust する仕組みなので、`hooks.json` を置く/変えるだけでは走らない。

**未 trust の hook グループは、警告も出さずに黙って飛ばされる**（実測。`codex exec` でも
「trust されていない」旨の表示は一切出ず、ツール呼び出しがそのまま成功する）。
つまり `hooks.json` を編集したあと trust し直すまで、ガードは配線されているのに無効なままになる。
ガードを足す/変える変更では、**trust と発火確認までやって初めて完了**とみなすこと。

1. `setup.sh` で `~/.codex/hooks.json` を symlink（または既に symlink 済み）。
2. Codex を起動し、`/hooks` で新しい hook を **trust** する。
   trust 済みのグループは `~/.codex/config.toml` の `[hooks.state."<path>:<event>:<group>:<index>"]` に出る。
3. 発火を確かめる。使い捨てディレクトリで:

   ```
   codex exec -s workspace-write 'シェルで `grep -rn foo .` を実行して、結果をそのまま報告して'
   ```

   `guard-bash-command.sh` の「grep でなく rg を使う」ブロックが出れば効いている。
   何事もなく成功したら、まだ trust されていない。
   ついでに `apply_patch`（ファイル編集）を 1 回させて、パッチ本文が `Bash` matcher に
   誤爆していないことも確認する。
4. Codex が `~/.codex/hooks.json` を自動読込しない環境では、`~/.codex/config.toml` の
   トップレベルに `hooks = "hooks.json"` を追加する（`[projects]` などのセクションより前に置くこと）。

`config.toml` は Codex がランタイム値（モデルの NUX カウンタ等）を書き込むため dotfiles では管理しない。
