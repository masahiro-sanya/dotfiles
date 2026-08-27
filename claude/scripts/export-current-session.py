#!/usr/bin/env python3
"""現在の Claude Code セッションを frontmatter 付き Markdown として書き出す。

claude-session-manager プラグインの export は cwd プロジェクト内の「mtime 最新 JSONL」を
source にするため、同一プロジェクトで複数タブ（複数セッション）が走っていると別セッションを
書き出してしまう。このスクリプトは環境変数 CLAUDE_CODE_SESSION_ID で「今いるセッション」を
確実に指定して書き出す。出力形式・保存先はプラグインと揃えてあり、import-claude-session で
そのまま読み込める。

使い方:
  export-current-session.py [保存先ディレクトリ]
  # 省略時は ~/claude-sessions/（プラグインの既定と同じ）
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path

CLAUDE_PROJECTS_DIR = Path.home() / ".claude" / "projects"
DEFAULT_SESSIONS_DIR = Path.home() / "claude-sessions"


def resolve_session_file() -> Path | None:
    """CLAUDE_CODE_SESSION_ID から現セッションの JSONL を特定する。
    env が無い場合のみ cwd プロジェクト内の最新 JSONL にフォールバックする。"""
    project_dir = CLAUDE_PROJECTS_DIR / str(Path.cwd()).replace("/", "-")
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if session_id:
        candidate = project_dir / f"{session_id}.jsonl"
        if candidate.exists():
            return candidate
        print(
            f"警告: CLAUDE_CODE_SESSION_ID={session_id} の JSONL が見つからず、"
            "最新 JSONL にフォールバックします",
            file=sys.stderr,
        )
    if project_dir.exists():
        jsonl = list(project_dir.glob("*.jsonl"))
        if jsonl:
            return max(jsonl, key=lambda f: f.stat().st_mtime)
    return None


def extract_messages(jsonl_path: Path) -> list[dict]:
    """JSONL から user/assistant のテキストと Bash コマンドを抽出する
    （プラグインの export-session.py と同じ抽出ロジックに合わせている）。"""
    messages: list[dict] = []
    with open(jsonl_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") not in ("user", "assistant"):
                continue
            content = entry.get("message", {}).get("content", "")
            if isinstance(content, list):
                text_parts, bash_commands = [], []
                for block in content:
                    if isinstance(block, str):
                        text_parts.append(block)
                    elif isinstance(block, dict):
                        if block.get("type") == "text":
                            text_parts.append(block.get("text", ""))
                        elif block.get("type") == "tool_use" and block.get("name") == "Bash":
                            cmd = block.get("input", {}).get("command", "")
                            if cmd:
                                bash_commands.append(cmd)
                text = "\n".join(text_parts)
                if text:
                    messages.append({"role": entry["type"], "content": text})
                for cmd in bash_commands:
                    messages.append({"role": "command", "content": cmd})
            elif content:
                messages.append({"role": entry["type"], "content": content})
    return messages


def messages_to_markdown(messages: list[dict], project: str, session_id: str) -> str:
    now = datetime.now()
    lines = [
        "---",
        f"date: {now.strftime('%Y-%m-%d')}",
        f"project: {project}",
        f"session_id: {session_id}",
        "tags:",
        "  - claude-session",
        "---",
        "",
    ]
    for msg in messages:
        if msg["role"] == "command":
            lines += ["#### Command", "", "```bash", msg["content"], "```", ""]
        else:
            label = "User" if msg["role"] == "user" else "Assistant"
            lines += [f"#### {label}", "", msg["content"], ""]
    return "\n".join(lines)


def main() -> None:
    sessions_dir = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else DEFAULT_SESSIONS_DIR
    sessions_dir.mkdir(parents=True, exist_ok=True)

    session_file = resolve_session_file()
    if session_file is None:
        print("エラー: セッションファイルが見つかりません", file=sys.stderr)
        sys.exit(1)

    messages = extract_messages(session_file)
    if not messages:
        print("エラー: セッションにメッセージが含まれていません", file=sys.stderr)
        sys.exit(1)

    project = Path.cwd().name or "unknown"
    session_id = session_file.stem
    markdown = messages_to_markdown(messages, project, session_id)

    filename = f"{project}-{session_id[:8]}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.md"
    output_path = sessions_dir / filename
    output_path.write_text(markdown, encoding="utf-8")

    print(f"source : {session_file}")
    print(f"messages: {len(messages)}")
    print(f"saved  : {output_path}")


if __name__ == "__main__":
    main()
