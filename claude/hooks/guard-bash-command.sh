#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash)
# CLAUDE.md の散文ルールの機械化:
#   - grep/find をコマンド位置で検知してブロックし rg/fd へ誘導
#   - git の --no-verify をブロック（「テストを無効化・スキップしない」）
#   - main/master への直接 git commit をブロック（「feature branchで作業」）
#   - 監査ログ（guard-hits / hooks-error / traces）の削除・上書きをブロック
#   - --dangerously-skip-permissions の実行をブロック（Light ガイドライン）
# exit 2 + stderr で Claude にブロック理由が差し戻される

set -u

# fail-open（入力異常で exit 0）する経路の痕跡を残す。ログ失敗で hook 自体は壊さない。
# テスト用に HOOKS_ERROR_LOG で差し替え可。
HOOKS_ERROR_LOG="${HOOKS_ERROR_LOG:-${HOME}/.claude/hooks-error.log}"
log_fail() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') guard-bash-command.sh: $1" >> "${HOOKS_ERROR_LOG}" 2>/dev/null || true
}

# jq が入力パースに失敗したときの診断文字列。生データ（コマンド全文＝機密の恐れ）は残さず、
# 入力バイト数と jq のパースエラー位置（何バイト目で切れたか）だけを残して真因を次回捕捉する。
diag_input() {
    _bytes="$(printf '%s' "$1" | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    _jqerr="$(printf '%s' "$1" | /usr/bin/jq -r '.' 2>&1 1>/dev/null | /usr/bin/tr '\t\n' '  ' | /usr/bin/cut -c1-160)"
    printf 'bytes=%s jqerr=[%s]' "${_bytes}" "${_jqerr}"
}

# ブロック（exit 2）発火を1行TSVで記録する。誤爆・死物を後から追うためのテレメトリ。
# ベストエフォート: 記録に失敗してもブロック自体は壊さない。テスト用に GUARD_HITS_LOG で差し替え可
GUARD_HITS_LOG="${GUARD_HITS_LOG:-${HOME}/.claude/guard-hits.log}"
log_block() {
    detail="$(printf '%s' "$2" | /usr/bin/tr '\t\n' '  ' | /usr/bin/cut -c1-200)"
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" 'guard-bash-command' "$1" "${detail}" \
        >> "${GUARD_HITS_LOG}" 2>/dev/null || true
}

input="$(cat)"
cmd="$(printf '%s' "${input}" | /usr/bin/jq -r '.tool_input.command // empty' 2>/dev/null)"
jq_status=$?
if [ "${jq_status}" -ne 0 ]; then
    log_fail "jq parse failed (exit ${jq_status}) $(diag_input "${input}")"
    exit 0
fi
# command キー不在は Bash 以外のペイロード等の正常 skip（ログしない）
[ -z "${cmd}" ] && exit 0

# コマンド位置（行頭・パイプ・; & の直後・$( や ` の直後）のみ検知する。
# 境界: `git grep` や引数・文字列中の grep/find は許容（コマンド位置に来ないため）。
# 検知漏れ許容: xargs/env/time 経由の間接実行までは追わない。
cmd_pos='(^|[|;&(]|\$\(|`)[[:space:]]*(command[[:space:]]+)?(sudo[[:space:]]+)?'

# クォート内（コミットメッセージ・rg のパターン等のデータ）を除去した形。
# grep/find・--no-verify・git commit の判定はこちらを使い、データとしての言及で誤爆させない。
# 実測: `rg -n -e 'a|grep b' f` のようにクォート内の | をパイプと誤認して grep 判定が誤爆していた。
# 併せて `||`（論理 OR）を `;` に正規化する。下の grep_pos はパイプ受け側を許可するために
# アンカーから | を外しており、正規化しないと `false || grep -rn x src/` が素通りするため。
# `||` の後ろは前段の出力を受けない独立コマンド＝コードベース検索そのものなので検知対象。
# 既知の穴: コマンド語自体をクォートした形（`"grep" -rn x .`）は語ごと消えて検知できない。
# クォートを剥がして中身を残す形にすると `rg -n 'a|grep b'` の誤爆が戻るため、そのまま許容する
# （このガードは自分の手癖を直すためのもので、回避を試みる相手を想定した境界ではない）。
cmd_stripped="$(printf '%s' "${cmd}" | /usr/bin/perl -0777 -pe "s/\"[^\"]*\"//gs; s/'[^']*'//gs; s/\|\|/;/gs" 2>/dev/null || printf '%s' "${cmd}")"

# リモートシェル（adb shell / docker exec / ssh 等）の内側には rg/fd が無いが、
# そのための専用の除外は置かない。実測: guard-hits.log にある該当 5 件はいずれも
# 内側のコマンドがクォート内（= cmd_stripped で消える）か、コマンド位置に来ない
# （`docker compose exec -T app grep ...` の grep は区切り直後ではない）ため、
# 下の 2 つの判定だけで既に素通りする。
# 「行に ssh/docker exec 等を含むならスキップ」という形の除外は、
# `ssh host true && grep -rn secret .` でガード全体を迂回できてしまうので採らない。

# grep はパイプの受け側を検知しない（cmd_pos から | を外した grep_pos を使う）。
# `git show | grep` や `rg ... | grep` は既に別コマンドが出した出力の絞り込みで、
# rg に替えても速度も gitignore 考慮も効かない＝ルールの狙い（コードベース検索は rg）の外側。
# 実測: grep 差し戻し 342 件のうち 156 件がこの形で、往復コストだけ払っていた。
# 検知漏れ許容: `true | grep -rn pattern src/` のような前置きパイプ経由の検索は素通りする。
grep_pos='(^|[;&(]|\$\(|`)[[:space:]]*(command[[:space:]]+)?(sudo[[:space:]]+)?'

# さらに「コードベース検索の形をしている grep」だけに絞る。
# ルールの狙いは速度と gitignore 考慮なので、どちらも効かない使い方は対象外:
#   - 単一ファイルの grep（grep -n pattern path/to/one.md）
#   - 引数を取らない grep（grep --version、パイプ後の再絞り込み）
# 実測: 発火 260 件のうち狙いに合致したのは 40 件（15%）で、残り 85% は
# ブロック→書き直しの往復コストだけ払っていた（guard-hits.log 2026-07-08〜08-26）。
# 検知する形（次の区切りまでの範囲に現れたとき）:
#   -r/-R を含む短オプション（-rn, -rln, -nr 等）/ --recursive
#   --include / --exclude-dir（複数ファイル走査が前提）
#   グロブ * / 末尾が / のディレクトリ指定
# オプション判定と探索対象判定は前置きの形が違うので 2 本に分ける。
# オプション側は「区切り直後 or 空白直後の - 」に限定する。単に [[:space:]]- とすると
# grep 直後の空白を消費済みで -rn を拾えず、逆に空白を要求しないと --version の
# "-version" が -(ve)(r)(sion) として再帰オプションに誤マッチする（両方とも実測で確認）。
grep_opt='[[:space:]]+([^|;&]*[[:space:]])?(-[[:alnum:]]*[rR][[:alnum:]]*([[:space:]]|$)|--recursive|--include|--exclude-dir)'
grep_target='[[:space:]][^|;&]*(\*|[^[:space:]]/([[:space:]]|$))'
if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${grep_pos}(grep|egrep|fgrep)${grep_opt}" \
    || printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${grep_pos}(grep|egrep|fgrep)${grep_target}"; then
    log_block "grep-blocked" "${cmd}"
    echo "コードベース検索に grep は使わない（CLAUDE.md）。rg（ripgrep）で書き直してください。例: rg -n 'pattern' path/" >&2
    exit 2
fi

# find は stdin を読まないため、パイプの受け側でもファイルシステム検索のまま＝ cmd_pos のまま検知する。
#
# ただし fd に置き換えられない形は素通しする（実測 186 件中 76 件がこれに該当）:
#   - -exec / -mtime / -newer / -size / -delete / -prune / -depth
#     ＝ fd に等価形が無い、または意味が変わるもの
#   - find / や find ~ の全体探索
#     ＝ コードベース検索ではなく、fd は隠しファイル・ignore の既定が違って等価にならない
# 残る「特定ディレクトリ配下の -name/-iname 検索」だけが fd の素直な置き換え対象。
find_skip='([^|;&]*(-exec|-mtime|-newer|-size|-delete|-prune|-depth([[:space:]]|$)))'
find_root='[[:space:]]+(/|~|\$HOME)([[:space:]]|$)'
if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}find([[:space:]]|$)" \
    && ! printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}find[[:space:]]${find_skip}" \
    && ! printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}find${find_root}"; then
    log_block "find-blocked" "${cmd}"
    echo "ディレクトリ配下のファイル検索に find は使わない（CLAUDE.md）。fd で書き直す: find <dir> -name/-iname 'X' → fd 'X' <dir>（小文字パターンは既定で大文字小文字無視）。gitignore/隠しファイルも含めるなら fd -H -I 'X' <dir>。拡張子検索は fd -e go。-exec/-mtime 等と / 直下の全体探索はブロックしていない" >&2
    exit 2
fi

# 素の rm をブロック（CLAUDE.md「この環境の rm は -i エイリアス。非対話実行では
# 削除されないまま exit 0 になる → command rm -f を使い ls で裏取り」の機械化）。
# 正規の回避形である `command rm` / `sudo rm`（どちらもエイリアスを迂回する）は許可したいので、
# cmd_pos の command/sudo プレフィックス付きアンカーは使わず、区切り直後の rm だけを検知する。
# `command rm` は rm が区切り直後に来ない（command の後）ため、この pattern には一致しない。
#
# grep/find と違い、判定は cmd_stripped ではなく生の cmd で行う（クォート内の言及でも発火する）。
# これは意図的な据え置き。実測: guard-hits.log 2026-07-08〜08-27 の発火 231 件のうち、ログ上で
# 再現できた 156 件を分類すると cmd_stripped に替えて救えるのは 2 件（1.3%）だけだった
# （どちらも rg の検索パターンに rm -rf と書いた回）。grep は 85%・find は 41% が無駄で絞る
# 根拠があったが、ここには無い。加えてこれは作法ではなく「消えたつもりで消えていない」実害を
# 止める安全ガードなので、緩める基準は本来もっと高い。さらに判定不能だった 75 件に含まれる
# heredoc 本文中の rm（10 件）は quote-strip では剥がれず、替えても救えない。
# 誤爆が増えたら下の cmd を cmd_stripped にするだけで済むが、いま動かす理由は無い。
rm_pos='(^|[|;&(]|\$\(|`)[[:space:]]*'
if printf '%s\n' "${cmd}" | /usr/bin/grep -qE "${rm_pos}rm([[:space:]]|$)"; then
    log_block "bare-rm-blocked" "${cmd}"
    echo "素の rm は使わない（CLAUDE.md）。この環境の rm は -i エイリアスで、非対話実行だと削除されないまま exit 0 になる。command rm -f で実行し、削除後に ls で裏取りしてください。" >&2
    exit 2
fi

# 監査ログの改変防止（Light ガイドライン「検知の回避をしない・監査ログを正当な理由なく
# 削除しない」の機械化）。対象: ~/.claude/guard-hits.log（guard 発火テレメトリ）・
# ~/.claude/hooks-error.log（fail-open 痕跡）・~/.claude/logs/traces/（trace ログ）。
# 破壊系コマンド（rm/mv/shred/unlink/truncate/tee/dd）が同一パイプライン区切り内で
# 監査ログパスに触れる、または上書きリダイレクト（> / >|。追記 >> は対象外）が監査ログを
# 指すときブロックする。読み取り（cat/rg/tail 等）・バックアップコピー（cp）・追記は許可。
# クォートで包んだパスでも改変はできてしまうため、quote-strip 前の生コマンドで判定する。
# 検知漏れ許容: sed -i / perl -i 等の in-place 編集や間接実行までは追わない。
audit_paths='\.claude/(guard-hits\.log|hooks-error\.log|logs/traces)'
if printf '%s\n' "${cmd}" | /usr/bin/grep -qE "${cmd_pos}(rm|mv|shred|unlink|truncate|tee|dd)[[:space:]][^|;&]*${audit_paths}" \
    || printf '%s\n' "${cmd}" | /usr/bin/grep -qE "(^|[^>])>[|]?[[:space:]]*[^[:space:]>]*${audit_paths}"; then
    log_block "audit-log-tamper-blocked" "${cmd}"
    echo "監査ログ（~/.claude/guard-hits.log・hooks-error.log・logs/traces/）の削除・移動・上書きはしない（Light AI利用ガイドライン: 監査ログを正当な理由なく削除しない）。読み取りと追記（>>）は可能。整理が必要ならユーザーが手動で行ってください。" >&2
    exit 2
fi

# 以降の --no-verify / git commit 検知も cmd_stripped（上で算出）で行う。
# コミットメッセージ本文に書いただけで誤爆しないようにするため。

# 権限確認の一括スキップ禁止（Light ガイドライン第3条の機械化）。
# クォート内の言及（ドキュメント・メッセージ）は cmd_stripped で除去済みのため誤爆しない。
if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -q -- '--dangerously-skip-permissions'; then
    log_block "dangerously-skip-blocked" "${cmd_stripped}"
    echo "--dangerously-skip-permissions は実行しない・提案しない（Light AI利用ガイドライン: 権限確認の一括スキップ禁止）。権限が要る操作は通常の許可フローで進めてください。" >&2
    exit 2
fi

if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}git[[:space:]][^|;&]*[[:space:]]--no-verify"; then
    log_block "no-verify-blocked" "${cmd_stripped}"
    echo "--no-verify は禁止（CLAUDE.md「テストを無効化・スキップしない」）。フックが失敗するなら原因を修正してください。" >&2
    exit 2
fi

# main/master への直接 commit をブロック（「feature branchで作業、mainには直接コミットしない」）
# 例外: リポ root に .claude-allow-main マーカーがあるリポ（main 直運用のメモ系リポ等）は許可。
# detached HEAD（branch --show-current が空）はリベース等の正当な操作なので許可。
if printf '%s\n' "${cmd_stripped}" | /usr/bin/grep -qE "${cmd_pos}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$)"; then
    commit_dir="$(printf '%s\n' "${cmd_stripped}" | /usr/bin/sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]+commit.*/\1/p' | head -1)"
    [ -z "${commit_dir}" ] && commit_dir="${PWD}"
    case "${commit_dir}" in "~"*) commit_dir="${HOME}${commit_dir#\~}" ;; esac
    branch="$(git -C "${commit_dir}" branch --show-current 2>/dev/null || true)"
    if [ "${branch}" = "main" ] || [ "${branch}" = "master" ]; then
        repo_root="$(git -C "${commit_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "${repo_root}" ] && [ ! -f "${repo_root}/.claude-allow-main" ]; then
            log_block "main-commit-blocked" "branch=${branch} ${cmd_stripped}"
            echo "main には直接コミットしない（CLAUDE.md）。feature branch を切ってから commit してください（例: git checkout -b feat/xxx）。このリポで main 直コミットを許可する場合はユーザー承認の上 repo root に .claude-allow-main を置く。" >&2
            exit 2
        fi
    fi
fi

exit 0
