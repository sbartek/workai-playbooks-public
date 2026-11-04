"""`workai-board --web`: the board as a read-only HTML page on 127.0.0.1 (card 01-142).

Same data (report.py --json --all), same columns, order, card lines and
project looks as the terminal board: the column logic and the card text come
from app.py, so the two cannot drift apart. Standard library only
(http.server); no JavaScript, no external CSS or fonts.

Privacy: it binds 127.0.0.1 and nothing else (there is no host option);
the phone reaches it through `tailscale serve <port>` (tailnet only, never
Funnel). GET and HEAD of `/` only; every other path is 404 and every other
method is refused (501), so there is nothing to write through. Pages are sent
with `Cache-Control: no-store` so a shared device does not keep them.
"""
from __future__ import annotations

import html
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from rich.text import Text

from . import data, looks
from .app import COLUMNS, STATUSES, card_text, column_cards
from .style import BG_236, DIM_241, ORANGE_208, RED_196, TEXT_230, TEXT_252

HOST = "127.0.0.1"  # never anything else; the tailnet reaches it through `tailscale serve`
DEFAULT_PORT = 8646
MAX_AGE = 300.0  # re-run report.py at least this often (so STALE ages), as the TUI does

BORDER_CSS = {  # the TUI's border styles, in CSS
    "round": "2px solid {c}; border-radius: 8px",
    "double": "4px double {c}; border-radius: 2px",
    "heavy": "3px solid {c}; border-radius: 0",
    "dashed": "2px dashed {c}; border-radius: 2px",
}

CSS = f"""
:root {{ color-scheme: dark; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; padding: 8px 16px 24px; background: #1c1c1c; color: {TEXT_252};
  font: 14px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
header {{ display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: baseline; padding: 4px 0 8px; color: {DIM_241}; }}
header h1 {{ font-size: 16px; margin: 0; color: {TEXT_230}; }}
nav a {{ color: {TEXT_252}; margin-right: 10px; }}
.warn {{ color: {ORANGE_208}; }}
.err {{ color: {RED_196}; }}
main {{ display: grid; grid-template-columns: repeat({len(COLUMNS)}, minmax(0, 1fr)); gap: 8px; }}
section > h2 {{ position: sticky; top: 0; z-index: 1; margin: 0 0 6px; padding: 2px 8px; font-size: 14px;
  background: {BG_236}; color: {TEXT_252}; }}
details {{ margin: 0 0 6px; padding: 4px 8px; }}
details.blocked {{ opacity: .55; }}
summary {{ cursor: pointer; list-style: none; overflow-wrap: anywhere; }}
summary::-webkit-details-marker {{ display: none; }}
.body {{ white-space: pre-wrap; overflow-wrap: anywhere; margin: 6px 0 2px; padding-top: 6px;
  border-top: 1px solid {BG_236}; color: {TEXT_252}; }}
.empty {{ color: {DIM_241}; padding: 0 8px; }}
@media (max-width: 760px) {{
  main {{ grid-template-columns: 1fr; gap: 16px; }}
}}
@media (min-width: 761px) {{ nav {{ display: none; }} }}
"""


def style_css(style: str) -> str:
    """A rich style string as the TUI writes them (`bold #ff0000`, `#626262`) -> inline CSS."""
    out = []
    for word in str(style).split():
        if word == "bold":
            out.append("font-weight:bold")
        elif word.startswith("#") and len(word) == 7:
            out.append(f"color:{word}")
    return ";".join(out)


def text_html(t: Text) -> str:
    """A rich Text (the TUI's card lines) as escaped HTML with the same colours."""
    plain = t.plain
    cuts = sorted({0, len(plain)} | {s.start for s in t.spans} | {s.end for s in t.spans})
    parts = []
    for a, b in zip(cuts, cuts[1:]):
        chunk = html.escape(plain[a:b]).replace("\n", "<br>")
        css = ";".join(filter(None, (style_css(s.style) for s in t.spans if s.start <= a and s.end >= b)))
        parts.append(f'<span style="{css}">{chunk}</span>' if css else chunk)
    return "".join(parts)


def column_header(column: str, cards: list[dict], next_info: dict) -> str:
    if column == "next":
        over = " over cap" if next_info.get("over_cap") else ""
        return f"next ({len(cards)}/{next_info.get('cap', 5)}){over}"
    return f"{column} ({len(cards)})"


def card_html(card: dict, now: float, look) -> str:
    colour = looks.hex_of(look) or "#6c6c6c"
    border = BORDER_CSS.get(look[1] if look else "round", BORDER_CSS["round"]).format(c=colour)
    blocked = " blocked" if card.get("flags", {}).get("blocked") else ""
    body = html.escape((card.get("body") or "").strip())
    return (f'<details class="card{blocked}" id="c{html.escape(card["label"])}" style="border:{border}">'
            f'<summary>{text_html(card_text(card, now))}</summary>'
            f'<div class="body">{body}</div></details>')


def render(report: dict, board_looks: looks.Looks, now: float | None = None, loaded_at: float | None = None) -> str:
    """The whole page for one report.py --json --all result."""
    now = time.time() if now is None else now
    cards = [c for c in report.get("cards", []) if c["status"] in STATUSES]
    next_info = report.get("next") or {}
    sections, nav = [], []
    for column in COLUMNS:
        col = column_cards(cards, column)
        head = column_header(column, col, next_info)
        items = "".join(card_html(c, now, board_looks.get(c["project"])) for c in col) or '<p class="empty">none</p>'
        sections.append(f'<section class="{column}" id="col-{column}"><h2>{html.escape(head)}</h2>{items}</section>')
        nav.append(f'<a href="#col-{column}">{html.escape(head)}</a>')
    hubs = len(report.get("hubs", []))
    stamp = datetime.fromtimestamp(loaded_at or now).strftime("%H:%M:%S")
    notes = [f'<span class="warn">{html.escape(w)}</span>'
             for w in list(next_info.get("warnings", [])) + list(report.get("warnings", []))]
    if board_looks.error:
        notes.append(f'<span class="err">{html.escape(board_looks.error)}</span>')
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<meta name=\"referrer\" content=\"no-referrer\">"
            f"<title>workai board</title><style>{CSS}</style></head><body>"
            f"<header><h1>workai board</h1><span>{hubs} hub{'s' if hubs != 1 else ''}, {len(cards)} cards, "
            f"read {stamp} (reload the page to refresh)</span>{''.join(notes)}"
            f"<nav>{''.join(nav)}</nav></header>"
            f"<main>{''.join(sections)}</main></body></html>")


class Source:
    """report.py's data, re-read only when a card file changed (or after MAX_AGE), like the TUI."""

    def __init__(self, root: Path, report: Path, archives: bool = False) -> None:
        self.root, self.report, self.archives = root, report, archives
        self.lock = threading.Lock()
        self.data: dict | None = None
        self.sig: tuple = ()
        self.loaded_at = 0.0
        self.looks = looks.Looks(root)

    def page(self) -> str:
        with self.lock:
            sig = data.signature(self.root, self.archives)
            if self.data is None or sig != self.sig or time.time() - self.loaded_at > MAX_AGE:
                self.data = data.load(self.root, self.report, self.archives)
                self.sig, self.loaded_at = sig, time.time()
                # Same looks file as the TUI (its only write: a new project's first look).
                self.looks = looks.Looks(self.root)
                self.looks.assign(c["project"] for c in self.data.get("cards", []))
            return render(self.data, self.looks, loaded_at=self.loaded_at)


class Handler(BaseHTTPRequestHandler):
    """GET / and HEAD / only. Unknown methods (POST, PUT, ...) get http.server's 501."""

    source: Source  # set on the subclass made by make_server
    server_version = "workai-board"
    sys_version = ""

    def _send(self, status: int, body: str, head_only: bool = False) -> None:
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.end_headers()
        if not head_only:
            self.wfile.write(raw)

    def _page(self, head_only: bool) -> None:
        if self.path.split("?", 1)[0] != "/":
            self._send(404, "<!doctype html><title>not found</title><p>not found</p>", head_only)
            return
        try:
            body = self.source.page()
        except data.ReportError as e:
            self._send(500, f"<!doctype html><title>report failed</title><p>report failed: {html.escape(str(e))}</p>",
                       head_only)
            return
        self._send(200, body, head_only)

    def do_GET(self) -> None:  # noqa: N802 (http.server's name)
        self._page(False)

    def do_HEAD(self) -> None:  # noqa: N802
        self._page(True)

    def log_message(self, format: str, *args) -> None:  # quiet: one line per request on stderr is noise
        pass


def make_server(root: Path, report: Path, archives: bool = False, port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    """A server bound to 127.0.0.1:port (port 0 = any free port, for tests). Not started."""
    handler = type("BoundHandler", (Handler,), {"source": Source(root, report, archives)})
    return ThreadingHTTPServer((HOST, port), handler)


def serve(root: Path, report: Path, archives: bool = False, port: int = DEFAULT_PORT) -> None:
    server = make_server(root, report, archives, port)
    host, real_port = server.server_address[:2]
    print(f"workai-board web view on http://{host}:{real_port}/ (read-only; Ctrl-C stops)")
    print(f"phone over Tailscale: tailscale serve --bg {real_port}   (tailnet only; never funnel)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
