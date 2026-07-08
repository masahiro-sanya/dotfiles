#!/usr/bin/env python3
"""agent-usage.py — Task(subagent_type) の委譲実績を集計する。

~/.claude/projects 配下の全セッション jsonl を走査し、直近 N 日（既定 14）に
発行された Task 委譲を subagent_type 別に集計する。自作エージェントに実際に
委譲が移ったか（general-purpose 依存が減ったか）を測るための計測用。

usage: agent-usage.py [days]
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path.home() / ".claude" / "projects"

# 自作エージェント（このリポの claude/agents/ で定義したもの）
CUSTOM = {
    "investigator", "gcp-log-investigator", "palmu-api-researcher",
    "verify-runner", "pr-review-triage",
}
# Claude Code 組み込み
BUILTIN = {
    "general-purpose", "Explore", "fork", "Plan", "claude",
    "statusline-setup", "claude-code-guide",
}


def parse_ts(rec):
    ts = rec.get("timestamp")
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def walk(days):
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    counts = {}
    for f in ROOT.glob("*/*.jsonl"):
        try:
            fh = f.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                # 高速パス: subagent_type を含まない行は即スキップ
                if '"subagent_type"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = parse_ts(rec)
                if ts is not None and ts < cutoff:
                    continue
                msg = rec.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    inp = block.get("input")
                    if not isinstance(inp, dict):
                        continue
                    st = inp.get("subagent_type")
                    if isinstance(st, str) and st:
                        counts[st] = counts.get(st, 0) + 1
    return counts


def main():
    days = 14
    if len(sys.argv) > 1:
        try:
            days = int(sys.argv[1])
        except ValueError:
            print(f"usage: {sys.argv[0]} [days]", file=sys.stderr)
            return 2

    counts = walk(days)
    if not counts:
        print(f"直近 {days} 日: Task 委譲の記録なし")
        return 0

    total = sum(counts.values())
    custom = sum(v for k, v in counts.items() if k in CUSTOM)
    gp = counts.get("general-purpose", 0)
    builtin = sum(v for k, v in counts.items() if k in BUILTIN)
    other = total - custom - builtin

    print(f"== Task 委譲実績（直近 {days} 日） ==")
    print(
        f"合計 {total} / 自作 {custom} / general-purpose {gp} / "
        f"その他組み込み {builtin - gp} / プラグイン等 {other}"
    )
    print()
    width = max(len(k) for k in counts)
    for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        tag = "★" if k in CUSTOM else (" " if k in BUILTIN else "・")
        print(f"  {tag} {k.ljust(width)}  {v}")
    print()
    print("★=自作エージェント / 無印=組み込み / ・=プラグイン等")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
