"""`workai-board --web` (card 01-142): the read-only HTML view."""
from __future__ import annotations

import http.client
import re
import threading

import pytest
from conftest import REPORT, snapshot, write_card

from workai_board import web
from workai_board.app import COLUMNS, WorkaiBoard
from workai_board.cli import parse_args

SIZE = (180, 50)


@pytest.fixture
def server(workai):
    srv = web.make_server(workai, REPORT, port=0)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv
    srv.shutdown()
    srv.server_close()


def request(srv, method="GET", path="/", body=None):
    host, port = srv.server_address[:2]
    conn = http.client.HTTPConnection(host, port, timeout=30)
    conn.request(method, path, body=body)
    r = conn.getresponse()
    out = (r.status, dict(r.getheaders()), r.read().decode())
    conn.close()
    return out


def columns_of(page: str) -> dict[str, list[str]]:
    out = {}
    for col, inner in re.findall(r'<section class="(\w+)" id="col-\w+">(.*?)</section>', page, re.S):
        out[col] = re.findall(r'<details class="card[^"]*" id="c([0-9]{2}-[0-9]{3})"', inner)
    return out


def headers_of(page: str) -> dict[str, str]:
    return dict(re.findall(r'<section class="(\w+)" id="col-\w+"><h2>(.*?)</h2>', page))


async def test_same_cards_per_column_as_the_tui(workai, server):
    (workai / "next.md").write_text("02-001\n")
    status, headers, page = request(server)
    assert status == 200 and headers["Content-Type"] == "text/html; charset=utf-8"
    got = columns_of(page)
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        tui = {s: [b.card["label"] for b in app.columns[s].boxes] for s in COLUMNS}
        tui_headers = {s: str(app.columns[s].header.content) for s in COLUMNS}
    assert list(got) == list(COLUMNS)
    assert got == tui
    assert got["next"] == ["02-001"] and "02-001" not in got["todo"]
    assert headers_of(page) == tui_headers


def test_flags_body_and_look(workai, server):
    _, _, page = request(server)
    assert "WAIT" in page and "question for the user" in page          # waiting card
    assert "STALE" in page and "BLOCKED" in page                      # stale doing card, blocked todo
    assert 'class="card blocked"' in page                             # dimmed like the TUI
    assert "Paragraph 59 of a long body." in page                     # the body, expandable
    assert "border:2px solid #3987e5" in page                         # hub 01's look (blue, round)


def test_page_follows_card_changes(workai, server):
    _, _, before = request(server)
    assert "02-004" not in before
    write_card(workai, "projects/02-beta", "todo", "004", "Brand new", priority=1)
    _, _, after = request(server)
    assert "02-004" in columns_of(after)["todo"]


def test_text_is_escaped(workai, server):
    write_card(workai, "projects/02-beta", "todo", "005", "Tag <b>", priority=1, body="<script>x</script>")
    _, _, page = request(server)
    assert "<script>" not in page and "&lt;script&gt;" in page
    assert "<b>" not in page and "Tag &lt;b&gt;" in page


def test_binds_loopback_only_and_has_no_write_endpoints(workai, server):
    before = snapshot(workai)
    assert server.server_address[0] == "127.0.0.1" and web.HOST == "127.0.0.1"
    for method in ("POST", "PUT", "DELETE", "PATCH"):
        status, _, _ = request(server, method, "/", body="x")
        assert status == 501, method
    assert request(server, "GET", "/anything")[0] == 404
    assert request(server, "HEAD", "/")[0] == 200
    status, headers, _ = request(server)
    assert headers["Cache-Control"] == "no-store"
    assert "default-src 'none'" in headers["Content-Security-Policy"]
    assert snapshot(workai) == before


def test_report_failure_is_a_500_not_a_crash(workai, tmp_path):
    bad = tmp_path / "bad.py"
    bad.write_text("import sys; print('boom', file=sys.stderr); sys.exit(3)\n")
    srv = web.make_server(workai, bad, port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        status, _, page = request(srv)
        assert status == 500 and "report failed: boom" in page
    finally:
        srv.shutdown()
        srv.server_close()


def test_cli_web_options():
    a = parse_args(["--web", "--port", "9000"])
    assert a.web and a.port == 9000
    a = parse_args([])
    assert not a.web and a.port is None
    with pytest.raises(SystemExit):
        parse_args(["--web", "--host", "0.0.0.0"])  # there is no host option


def test_port_without_web_is_refused(workai, capsys):
    from workai_board.cli import main
    assert main(["--port", "9000"]) == 2
    assert "--port needs --web" in capsys.readouterr().err
