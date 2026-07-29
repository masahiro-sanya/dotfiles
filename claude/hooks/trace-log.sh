#!/usr/bin/env bash
# trace-log.sh — PostToolUse hook for Claude Code (user-level)
# Appends a JSONL line per tool call to ~/.claude/logs/traces/YYYY-MM-DD.jsonl.
# Designed to fail-open: any error here should never break the harness.
#
# Reads tool result from stdin (JSON with session_id, tool_name, tool_input, tool_response).
# Logs are local-only and never leave the device.

set -uo pipefail  # NOTE: no -e — we want to swallow failures
umask 077         # Restrict log file permissions to user only

INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

LOG_DIR="${HOME:-/tmp}/.claude/logs/traces"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
chmod 700 "$LOG_DIR" 2>/dev/null || true

DATE=$(date +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/${DATE}.jsonl"

CWD_HINT="${CLAUDE_PROJECT_DIR:-${PWD:-}}"

# Python プログラムは「temp ファイル」で渡す。stdin に heredoc で流すと、その同じ
# stdin に $INPUT も流れて衝突し、`python3 -` がプログラムを heredoc から読んだ後の
# json.load(sys.stdin) が空ストリームを読んで失敗 → サイレントに無記録になる
# （2026-05-15 にこの形で混入し約26日ログが停止した実績あり）。プログラム(ファイル)と
# データ(stdin パイプ)を別チャネルに分ける。
PROG="$(mktemp "${TMPDIR:-/tmp}/trace-log.XXXXXX.py" 2>/dev/null)" || exit 0
trap 'rm -f "$PROG"' EXIT
cat > "$PROG" <<'PYEOF'
import json, sys, os, time, re

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool = data.get('tool_name', '')
tinp = data.get('tool_input', {}) or {}
tresp = data.get('tool_response', {})
session = data.get('session_id', '')

input_summary = {}
if isinstance(tinp, dict):
    if tool == 'Bash':
        cmd = tinp.get('command', '')
        input_summary['command'] = cmd[:200] + ('…' if len(cmd) > 200 else '')
        if 'description' in tinp:
            input_summary['description'] = tinp.get('description', '')[:120]
    elif tool in ('Read', 'Edit', 'Write'):
        input_summary['file_path'] = tinp.get('file_path', '')
    elif tool == 'WebFetch':
        input_summary['url'] = tinp.get('url', '')
    elif tool == 'WebSearch':
        q = tinp.get('query', '')
        input_summary['query'] = q[:120]
    elif tool == 'Agent':
        input_summary['description'] = tinp.get('description', '')
        input_summary['subagent_type'] = tinp.get('subagent_type', '')
    elif tool == 'Skill':
        input_summary['skill'] = tinp.get('skill', '')
    elif tool.startswith('mcp__'):
        input_summary['mcp_keys'] = list(tinp.keys())[:5]
    else:
        input_summary['keys'] = list(tinp.keys())[:5] if isinstance(tinp, dict) else []

resp_summary = {}
# --- content length (shape-tolerant) ---
content = tresp.get('content') if isinstance(tresp, dict) else tresp
if isinstance(content, str):
    resp_summary['content_len'] = len(content)
elif isinstance(content, list):
    total = 0
    for c in content:
        if isinstance(c, dict):
            total += len(str(c.get('text', '')))
    resp_summary['content_len'] = total

# --- error detection (shape-tolerant) ---
# 旧実装は tool_response が dict のときしか is_error を見ず、Bash 非ゼロ終了 /
# <tool_use_error> / 文字列レスポンスのエラーを全て is_error:false に化けさせていた
# (観測層が片肺になる)。実テキスト(content/stdout/stderr)を取り出して判定する。
def _text(x):
    if isinstance(x, str):
        return x
    if isinstance(x, dict):
        parts = []
        for k in ('content', 'stdout', 'stderr', 'text', 'output', 'error'):
            v = x.get(k)
            if isinstance(v, str):
                parts.append(v)
            elif isinstance(v, list):
                for c in v:
                    if isinstance(c, dict) and isinstance(c.get('text'), str):
                        parts.append(c['text'])
            elif isinstance(v, dict):
                parts.append(json.dumps(v, ensure_ascii=False))
            elif v is not None:
                parts.append(str(v))
        return "\n".join(parts) if parts else json.dumps(x, ensure_ascii=False)
    try:
        return json.dumps(x, ensure_ascii=False)
    except Exception:
        return str(x)

is_err = False
err_kind = ''
if isinstance(tresp, dict) and (tresp.get('is_error') or tresp.get('error')):
    is_err, err_kind = True, 'flag'
if not is_err:
    text = _text(tresp)
    if '<tool_use_error>' in text:
        is_err, err_kind = True, 'tool_use_error'
    elif tool == 'Bash' and re.match(r'Exit code [1-9]\d*', text.lstrip()):
        # CC の Bash 失敗は応答冒頭が "Exit code N\n..."。先頭アンカーにして、
        # 成功コマンドの出力中に "Exit code 1" 行が混ざるだけの誤検知を防ぐ。
        is_err, err_kind = True, 'bash_nonzero'
if not is_err and data.get('is_error'):
    is_err, err_kind = True, 'flag_top'
resp_summary['is_error'] = is_err
if err_kind:
    resp_summary['err_kind'] = err_kind

project_hint = os.environ.get('PROJECT_HINT', '').rstrip('/')
record = {
    'ts': time.time(),
    'iso': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
    'session': session[:12] if session else '',
    'project': os.path.basename(project_hint) if project_hint else '',
    'tool': tool,
    'input': input_summary,
    'response': resp_summary,
}

log_file = os.environ.get('CLAUDE_TRACE_FILE', '')
if not log_file:
    sys.exit(0)
try:
    with open(log_file, 'a', encoding='utf-8') as f:
        f.write(json.dumps(record, ensure_ascii=False) + '\n')
except Exception:
    pass

sys.exit(0)
PYEOF

# プログラム(temp ファイル)とデータ($INPUT を stdin)を別チャネルで渡す。
printf '%s' "$INPUT" | CLAUDE_TRACE_FILE="$LOG_FILE" PROJECT_HINT="$CWD_HINT" python3 "$PROG" 2>/dev/null || true

exit 0
