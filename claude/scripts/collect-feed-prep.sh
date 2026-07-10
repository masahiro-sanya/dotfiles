#!/bin/bash
# collect-feed-prep: /morning 手順5（技術記事フィード収集）を launchd で朝前に実行する
#
# 背景（⑦-12 の帰結）:
# - collect-feed の Step 4 並列巡回は Workflow 前提で、Workflow は subagent では使えない。
#   morning から feed-collector（subagent）へ委譲すると単独直列の縮退で 20〜30 分かかる。
# - headless（claude -p）は main セッション＝Workflow がそのまま使えるため、朝前に launchd で
#   先に収集しておき、/morning は結果レポートを読むだけにする（対話セッション側のコストゼロ）。
#
# 設計方針:
# - morning-prep と同じ型: ログ追記・完了スタンプ・失敗してもログに残して正常終了
# - スタンプ（.collect-feed-last）は「claude が exit 0 かつレポートが今日更新」の時だけ書く。
#   /morning 手順5 はスタンプが今日ならレポートを読むだけ、無ければ従来どおり
#   feed-collector へ委譲する＝このジョブが落ちても朝は壊れない
# - プロンプトは stdin で渡す（--allowedTools は可変長引数で、後置の位置引数を
#   ツール名として飲み込み "Input must be provided" で落ちるため）
# - CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 が必須: print モードは既定でバックグラウンド
#   タスク待ちを 600 秒で打ち切る。collect-feed Step 4 の Workflow 巡回は background で
#   走るため、これが無いと Workflow 完了前に強制終了される（2026-07-11 実測）
# - 書き込みは --allowedTools で Tech Feed 系 Notion ツールと Slack 送信だけに限定
#   （それ以外は permission 自動拒否に倒す。guard hooks は headless でも有効）
# - macOS 標準 bash 3.2 互換で書く

set -u

LOG_FILE="${HOME}/.claude/collect-feed-prep.log"
STAMP_FILE="${HOME}/.claude/.collect-feed-last"
REPORT_FILE="${HOME}/.claude/collect-feed-report.md"

# launchd から起動されると brew / claude が PATH に無いため明示的に通す
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}"
}

mkdir -p "${HOME}/.claude"

today="$(date +%Y-%m-%d)"

# 今日すでに収集済みなら何もしない（手動実行との二重回避）
if [ "$(cat "${STAMP_FILE}" 2>/dev/null)" = "${today}" ]; then
    log "collect-feed-prep: SKIP (今日は収集済み)"
    exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
    log "collect-feed-prep: SKIP (claude が見つからない)"
    exit 0
fi

log "=== collect-feed-prep start ==="

prompt='技術記事フィード収集を実行して: Skill ツールで collect-feed:collect-feed を引数なしで起動し、フローを最後まで完遂する（設定読み込み→古い記事のアーカイブ→ソース巡回→重複除外→フィルタ→評価・分類→Notion登録→🚨確認必須記事がある時のみ #dev-times 通知→light-inc 横断調査→結果報告）。ここは main セッションなので Step 4 の Workflow 並列巡回がそのまま使える。スキルの規約（公開日検証をスキップしない・上限ルール・個人名を出さない・palmu/チーム視点）を厳守する。🚨該当が1件も無ければ Slack には何も投稿しない。完了したら (1) Step 10 の収集レポート全文を ~/.claude/collect-feed-report.md に Write で保存し（冒頭に実行日 '"${today}"' を記す）、(2) 最終出力にレポート要約と、permission 拒否やツール不可など実行できなかった部分があれば正直に明記する。登録していないものを登録したと言わない。'

allowed_tools='Read,Glob,Grep,Write,WebFetch,WebSearch,Skill,Workflow,Task,TodoWrite,Bash(date:*),mcp__notion__notion-search,mcp__notion__notion-fetch,mcp__notion__notion-create-pages,mcp__notion__notion-update-page,mcp__notion__notion-query-database-view,mcp__notion__notion-query-data-sources,mcp__plugin_slack_slack__slack_read_channel,mcp__plugin_slack_slack__slack_search_public,mcp__plugin_slack_slack__slack_send_message'

if printf '%s' "${prompt}" | CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 claude -p --model sonnet --allowedTools "${allowed_tools}" >> "${LOG_FILE}" 2>&1; then
    # 成功判定は返り値でなく実物で裏取り: レポートが今日書かれているか（mtime）
    report_day="$(stat -f '%Sm' -t '%Y-%m-%d' "${REPORT_FILE}" 2>/dev/null)"
    if [ "${report_day}" = "${today}" ]; then
        printf '%s\n' "${today}" > "${STAMP_FILE}"
        log "collect-feed-prep: OK (レポート更新・スタンプ記録)"
    else
        log "collect-feed-prep: FAILED (claude は exit 0 だがレポート未更新。スタンプは書かない)"
    fi
else
    log "collect-feed-prep: FAILED (claude exit != 0。スタンプは書かない → /morning は feed-collector に縮退)"
fi

log "=== collect-feed-prep done ==="
