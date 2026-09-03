#!/usr/bin/env python3
"""生成した解説HTMLをヘッドレスChromeで実際に描画し、結果を検証する。

1. 描画後のDOMから、Mermaidの図が全て描画されたかを機械的に確認する
2. ページ全体のスクリーンショットを1枚撮る（エージェントがReadして目視するため）

python3 標準ライブラリのみで動作する。Google Chrome を外部コマンドとして使う。
"""

from __future__ import annotations

import argparse, json, os, re, select, signal, subprocess, sys, tempfile, time
from pathlib import Path

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FALLBACK_HEIGHT = 12000  # ページ高さを取得できなかったときの撮影高さ
PNG_HEAD, PNG_TAIL = b"\x89PNG\r\n\x1a\n", b"IEND\xaeB`\x82"


def run_chrome(url: str, profile: Path, extra: list[str], timeout: int, done=None) -> str:
    """Chromeを起動し、成果物が出揃った時点で打ち切って標準出力を返す。

    --headless=new は --dump-dom / --screenshot を書き終えてもプロセスが残り、
    標準出力も閉じない。待っていても終わらないので、成果物そのものを見て
    完了を判定する（done）。timeout はその判定が効かなかったときの保険。
    子プロセスごと確実に止めるので独立したプロセスグループで起動する。
    """
    cmd = [CHROME, "--headless=new", "--disable-gpu", "--disable-crash-reporter",
           "--no-first-run", f"--user-data-dir={profile}", "--hide-scrollbars", *extra, url]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    buf, deadline = b"", time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 0.2)
            if ready:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    break  # Chrome が標準出力を閉じた＝出力は出揃っている
                buf += chunk
            if done and done(buf):
                break
            if not ready and proc.poll() is not None:
                break
    finally:
        if proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        proc.stdout.close()
        proc.wait()
    return buf.decode("utf-8", "replace")


def png_written(path: Path) -> bool:
    """PNG が最後まで書き終わっているか。IEND チャンクの有無で見る（途中で殺して壊さないため）"""
    try:
        if path.stat().st_size < len(PNG_HEAD) + len(PNG_TAIL):
            return False
        with path.open("rb") as f:
            if f.read(len(PNG_HEAD)) != PNG_HEAD:
                return False
            f.seek(-len(PNG_TAIL), os.SEEK_END)
            return f.read(len(PNG_TAIL)) == PNG_TAIL
    except OSError:
        return False


def attr(dom: str, name: str) -> str | None:
    m = re.search(r'data-%s="([^"]*)"' % re.escape(name), dom)
    return m.group(1) if m else None


def count_drawn(dom: str) -> int:
    """描画に成功した図の数。Mermaid は記法エラーでも同じ id で
    「Syntax error」の svg を差し込むので、それは成功に数えない"""
    return len([tag for tag in re.findall(r'<svg id="fig-\d+"[^>]*>', dom)
                if 'aria-roledescription="error"' not in tag])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("html")
    ap.add_argument("--width", type=int, default=1000)
    ap.add_argument("--wait", type=int, default=20000, help="描画を待つ仮想時間(ms)")
    ap.add_argument("--timeout", type=int, default=30, help="Chrome1回あたりの打ち切り秒数")
    a = ap.parse_args()

    html = Path(a.html).resolve()
    if not html.is_file():
        print(json.dumps({"ok": False, "error": f"ファイルが見つかりません: {html}"}, ensure_ascii=False)); return 1
    if not Path(CHROME).exists():
        print(json.dumps({"ok": False, "error": f"Google Chrome が見つかりません: {CHROME}"}, ensure_ascii=False)); return 1

    url, warnings = html.as_uri(), []
    shot = html.parent / f"{html.stem}-shot.png"
    # 前回の撮影結果を先に消す。残っていると撮影に失敗しても気づかず、
    # 古い見た目を「今の描画」として目視してしまう
    shot.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="understand-") as tmp:
        profile = Path(tmp) / "profile"
        dom = run_chrome(url, profile, [f"--window-size={a.width},1200",
                                        f"--virtual-time-budget={a.wait}", "--dump-dom"],
                         a.timeout, done=lambda b: b"</html>" in b)

        # 図の枚数はテンプレートが本文から数えて属性に出している。
        # DOM から数えると、描画済みの svg・未処理の pre・エラー時の
        # 差し込み svg が混ざって二重計上になる
        total, drawn = attr(dom, "mermaid-total"), attr(dom, "mermaid-ok")
        rendered = int(drawn) if drawn is not None else count_drawn(dom)
        if total is not None:
            sources = int(total)
        else:  # テンプレートの計数 script すら動かなかったとき
            sources = count_drawn(dom) + len(re.findall(r'<pre class="mermaid">\s*\w', dom))
        ready = attr(dom, "mermaid-ready") == "1"

        if not dom.strip():
            warnings.append("DOM を取得できなかった。Bash のサンドボックス内では Chrome が起動できないため、サンドボックス無しで再実行する")
        if sources and not ready:
            warnings.append("Mermaid の描画完了フラグが立っていない。CDN に到達できていないか記法エラー。サンドボックス無しで再実行する")
        if sources and rendered != sources:
            warnings.append(f"Mermaid の図が {sources} 個あるのに描画されたのは {rendered} 個。記法エラーか id の衝突が疑われる")
        for msg in re.findall(r'data-mermaid-error="([^"]*)"', dom):
            warnings.append(f"Mermaid の記法エラー: {msg}")

        m = re.search(r'data-page-height="(\d+)"', dom)
        height = int(m.group(1)) if m else 0
        if not height:
            height = FALLBACK_HEIGHT
            warnings.append(f"ページ高さを取得できなかった。既定の {FALLBACK_HEIGHT}px で撮影したため、末尾が切れていないか目視する")

        run_chrome(url, profile, [f"--window-size={a.width},{height + 40}",
                                  f"--virtual-time-budget={a.wait}", f"--screenshot={shot}"],
                   a.timeout, done=lambda _b: png_written(shot))
        if not png_written(shot):
            warnings.append("スクリーンショットを生成できなかった")

    title = re.search(r"<title>(.*?)</title>", dom, re.S)
    print(json.dumps({"ok": not warnings, "html": str(html),
                      "title": title.group(1).strip() if title else "",
                      "pageHeight": height, "mermaidSources": sources, "mermaidRendered": rendered,
                      "mermaidReady": ready, "screenshot": str(shot) if png_written(shot) else None,
                      "warnings": warnings}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
