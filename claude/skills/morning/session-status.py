#!/usr/bin/env python3
"""全プロジェクトのClaude Codeセッション進捗状況を表示する。

直近N時間以内に更新された .jsonl セッションを横断で見て、
プロジェクト別に最新セッションの「最後のやり取り」と「停止理由」を出す。

Usage:
    session-status.py [HOURS]   # デフォルト 72
"""
import json
import sys
import time
from pathlib import Path

HOURS = int(sys.argv[1]) if len(sys.argv) > 1 else 72

root = Path.home() / ".claude" / "projects"
cutoff = time.time() - HOURS * 3600

# subagents/ 配下は除外（メインセッションだけ見たい）
sessions = [p for p in root.glob("*/*.jsonl") if p.stat().st_mtime >= cutoff]


def decode_project(path: Path) -> str:
    name = path.parent.name
    if name.startswith("-"):
        return "/" + name[1:].replace("-", "/")
    return name


def summarize(p: Path):
    last_user = None
    last_assistant = None
    last_ts = None
    stop_reason = None
    # cwd は「最初に登場したもの」を採用（session 起動時の値。subagent/cd で変わる末尾は信用しない）
    cwd = None
    msgs = 0
    try:
        with p.open() as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")
                if cwd is None and d.get("cwd"):
                    cwd = d["cwd"]
                if d.get("timestamp"):
                    last_ts = d["timestamp"]
                if t == "user":
                    content = d.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        content = "\n".join(
                            c.get("text", "")
                            for c in content
                            if isinstance(c, dict) and c.get("type") == "text"
                        ).strip()
                    if isinstance(content, str) and content and not content.startswith("<"):
                        last_user = content
                        msgs += 1
                elif t == "assistant":
                    content = d.get("message", {}).get("content", [])
                    if isinstance(content, list):
                        texts = [
                            c.get("text", "")
                            for c in content
                            if isinstance(c, dict) and c.get("type") == "text"
                        ]
                        if texts:
                            last_assistant = "\n".join(texts).strip()
                    msgs += 1
                elif t == "system":
                    sr = d.get("stopReason")
                    if sr:
                        stop_reason = sr
    except Exception:
        return None
    return {
        "file": str(p),
        "cwd": cwd or decode_project(p),
        "last_ts": last_ts,
        "last_user": (last_user or "")[:200],
        "last_assistant": (last_assistant or "")[:200],
        "stop_reason": stop_reason,
        "msgs": msgs,
        "mtime": p.stat().st_mtime,
    }


results = [r for r in (summarize(p) for p in sessions) if r and r["msgs"] > 0]

# プロジェクト別に最新セッションだけ残す
by_project: dict[str, dict] = {}
for r in sorted(results, key=lambda r: r["mtime"], reverse=True):
    by_project.setdefault(r["cwd"], r)

ordered = sorted(by_project.values(), key=lambda r: r["mtime"], reverse=True)

print(f"# 直近 {HOURS}h のセッション進捗 ({len(ordered)} プロジェクト)\n")

for r in ordered:
    ts = r["last_ts"][:16].replace("T", " ") if r["last_ts"] else "?"
    stop = r["stop_reason"] or "-"
    print(f"## 📁 {r['cwd']}")
    print(f"- 最終: {ts} UTC / msgs={r['msgs']} / stop={stop}")
    if r["last_user"]:
        u = r["last_user"].replace("\n", " ")
        print(f"- 👤 {u}")
    if r["last_assistant"]:
        a = r["last_assistant"].replace("\n", " ")
        print(f"- 🤖 {a}")
    print()
