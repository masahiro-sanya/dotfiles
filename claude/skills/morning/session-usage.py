#!/usr/bin/env python3
"""セッション名ごとに、今の会話でユーザーが出した指示の数を数える。

/morning 手順 10 で、開き直すペインと閉じるペインを分ける材料にする。
同じ名前の記録のうち一番新しいもの（＝前回開き直してからの会話）だけを見る。
開き直しの /handoff 読むだけ・/exit・サブエージェントの完了通知・圧縮の続き書きは数えない。

Usage:
    session-usage.py <セッション名>...

出力（タブ区切り・1 行 1 セッション）:
    <名前> <指示の数> <最後の指示の頭 40 字>
記録が見つからない名前は指示の数を "-" にする（呼び出し側は「使われている」側に倒す）。
"""
import json
import mmap
import sys
import time
from pathlib import Path

ROOT = Path.home() / ".claude" / "projects"
# 開き直しは毎朝なので、これより古い記録は今の会話ではない
RECENT_DAYS = 30

# 人の指示ではない、自動で入る発話の書き出し
AUTO_PREFIXES = (
    "<task-notification>",
    "<local-command-",
    "<system-reminder>",
    "This session is being continued",
    "[Request interrupted by user",
)
# 開き直しの流れで送られるコマンド
AUTO_COMMANDS = ("/handoff", "/exit")


def prompt_text(entry):
    if entry.get("type") != "user" or entry.get("isMeta"):
        return None
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
        return "\n".join(texts) if texts else None
    return None


def is_user_prompt(text):
    s = text.lstrip()
    if not s or s.startswith(AUTO_PREFIXES):
        return False
    if "<command-name>" in s:
        name = s.split("<command-name>", 1)[1].split("</command-name>", 1)[0].strip()
        return name not in AUTO_COMMANDS
    return True


TITLE_KEY = b'"customTitle":"'


def current_title(path):
    """記録の最後の customTitle（＝今の名前）を返す。改名前の名前では拾わない。
    記録は大きいので全体を読み込まず、末尾から 1 回だけ探す"""
    with path.open("rb") as f:
        try:
            m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        except ValueError:  # 空のファイル
            return None
        with m:
            i = m.rfind(TITLE_KEY)
            if i < 0:
                return None
            start = i + len(TITLE_KEY)
            end = m.find(b'"', start)
            if end < 0:
                return None
            return m[start:end].decode("utf-8", errors="replace")


def latest_transcripts(names):
    """名前ごとに、その名前が付いた一番新しい記録を返す"""
    cutoff = time.time() - RECENT_DAYS * 86400
    wanted = set(names)
    latest = {}
    for p in ROOT.glob("*/*.jsonl"):
        try:
            mtime = p.stat().st_mtime
            if mtime < cutoff:
                continue
            name = current_title(p)
        except OSError:
            continue
        if name in wanted and (name not in latest or mtime > latest[name][0]):
            latest[name] = (mtime, p)
    return {name: p for name, (_, p) in latest.items()}


def count(path):
    n, last = 0, ""
    with path.open(errors="replace") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            text = prompt_text(entry)
            if text is not None and is_user_prompt(text):
                n += 1
                last = " ".join(text.split())[:40]
    return n, last


def main(names):
    if not names:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    found = latest_transcripts(names)
    for name in names:
        path = found.get(name)
        if path is None:
            print(f"{name}\t-\t記録が見つからない")
            continue
        n, last = count(path)
        print(f"{name}\t{n}\t{last}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
