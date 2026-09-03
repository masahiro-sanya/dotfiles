#!/usr/bin/env bash
# trace-summary.sh — Generate a daily summary of Claude Code trace logs.
# Usage: ~/.claude/scripts/trace-summary.sh [YYYY-MM-DD]
# Default: today.

set -euo pipefail

DATE="${1:-$(date +%Y-%m-%d)}"
LOG_FILE="${HOME}/.claude/logs/traces/${DATE}.jsonl"

if [ ! -f "$LOG_FILE" ]; then
    echo "No trace log for $DATE"
    echo "Looked for: $LOG_FILE"
    exit 0
fi

python3 - "$LOG_FILE" <<'PYEOF'
import json, sys
from collections import Counter, defaultdict

log_file = sys.argv[1]
total = 0
errors = 0
tool_counts = Counter()
mcp_counts = Counter()
agent_descs = []
skill_calls = Counter()
projects = Counter()
total_bytes = 0
sessions = set()

with open(log_file, encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        total += 1
        sessions.add(r.get('session', ''))
        tool = r.get('tool', '')
        tool_counts[tool] += 1
        if tool.startswith('mcp__'):
            mcp_counts[tool] += 1
        if r.get('response', {}).get('is_error'):
            errors += 1
        total_bytes += r.get('response', {}).get('content_len', 0) or 0
        proj = r.get('project', '')
        if proj:
            projects[proj] += 1
        if tool == 'Agent':
            d = r.get('input', {}).get('description', '')
            if d:
                agent_descs.append(d)
        if tool == 'Skill':
            s = r.get('input', {}).get('skill', '')
            if s:
                skill_calls[s] += 1

print(f"\n=== Trace summary for {log_file.split('/')[-1].replace('.jsonl','')} ===\n")
print(f"Total tool calls:  {total}")
print(f"Sessions:          {len(sessions)}")
print(f"Errors:            {errors}  ({errors*100//total if total else 0}%)")
print(f"Total response:    {total_bytes:,} bytes")

if projects:
    print(f"\nBy project:")
    for p, n in projects.most_common(10):
        print(f"  {n:5d}  {p}")

print(f"\nTop tools:")
for tool, n in tool_counts.most_common(10):
    print(f"  {n:5d}  {tool}")

if skill_calls:
    print(f"\nSkill invocations:")
    for s, n in skill_calls.most_common():
        print(f"  {n:5d}  {s}")

if agent_descs:
    print(f"\nAgent dispatches ({len(agent_descs)}):")
    for d in agent_descs[:10]:
        print(f"  - {d}")
    if len(agent_descs) > 10:
        print(f"  ... and {len(agent_descs)-10} more")

if mcp_counts:
    print(f"\nMCP usage:")
    for t, n in mcp_counts.most_common(8):
        print(f"  {n:5d}  {t}")
PYEOF
