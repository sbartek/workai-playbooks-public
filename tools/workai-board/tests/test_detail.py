"""Detail view: open, fields, markdown body, scroll, back, editor."""
from __future__ import annotations

import json
import sys

from conftest import snapshot

from workai_board.app import COLUMNS, WorkaiBoard
from workai_board.detail import DetailScreen, editor_command

SIZE = (120, 30)


async def open_card(pilot, label):
    """Select `label` on the board with keys, then press Enter."""
    app = pilot.app
    col = next(i for i, s in enumerate(COLUMNS) if label in [b.card["label"] for b in app.columns[s].boxes])
    await pilot.press("h", "h", *["l"] * col, "g")
    for _ in range(30):
        if app.selected_card["label"] == label:
            break
        await pilot.press("j")
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, DetailScreen)
    return app.screen


async def test_open_scroll_and_back_keeps_selection(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        await pilot.press("j", "j")  # 02-001, the card with a long body
        assert app.selected_card["label"] == "02-001"
        screen = await open_card(pilot, "02-001")
        assert screen.card["label"] == "02-001"
        assert "02-001 Beta first" in str(screen.query_one("#detail-title").content)
        body = screen.query_one("#detail-body")
        assert "Paragraph 59 of a long body." in body.source
        view = screen.viewport
        assert view.max_scroll_y > 0 and view.scroll_y == 0
        await pilot.press("j", "j", "j")
        await pilot.pause()
        assert view.scroll_y == 3
        await pilot.press("space")
        await pilot.pause()
        assert view.scroll_y > 3
        await pilot.press("G")
        await pilot.pause()
        assert view.scroll_y == view.max_scroll_y
        await pilot.press("g")
        await pilot.pause()
        assert view.scroll_y == 0
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, DetailScreen)
        assert app.selected_card["label"] == "02-001"
        selected = [b.card["label"] for c in app.columns.values() for b in c.boxes if b.has_class("selected")]
        assert selected == ["02-001"]


async def test_fields_shown(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await pilot.press("l", "j")  # 01-006 (waiting), now in the Waiting column
        screen = await open_card(pilot, "01-006")
        table = screen.query_one("#detail-fields").content
        cells = {str(table.columns[0]._cells[i]): str(table.columns[1]._cells[i]) for i in range(table.row_count)}
        assert cells["Claimed by"] == "agent A"
        assert cells["Waiting"] == "question for the user"
        assert cells["Flags"] == "WAIT"
        assert cells["Status"] == "doing"
        assert cells["File"].endswith("backlog/doing/006-ask-about-colours.md")


async def test_dependencies_listed(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        screen = await open_card(pilot, "01-003")
        table = screen.query_one("#detail-fields").content
        cells = {str(table.columns[0]._cells[i]): str(table.columns[1]._cells[i]) for i in range(table.row_count)}
        assert cells["Depends"] == "01-001" and cells["Dependents"] == "01-004"


async def test_backspace_also_goes_back(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await open_card(pilot, "01-003")
        await pilot.press("backspace")
        await pilot.pause()
        assert not isinstance(pilot.app.screen, DetailScreen)


async def test_E_launches_editor_without_writing(workai, tmp_path, monkeypatch):
    log = tmp_path / "editor.json"
    stub = tmp_path / "stub_editor.py"
    stub.write_text(f"import json, sys\njson.dump(sys.argv[1:], open({str(log)!r}, 'w'))\n")
    monkeypatch.setenv("VISUAL", f"{sys.executable} {stub} --flag")
    before = snapshot(workai)
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        screen = await open_card(pilot, "01-003")
        await pilot.press("E")
        await pilot.pause(0.3)
        assert isinstance(pilot.app.screen, DetailScreen)
    assert json.loads(log.read_text()) == ["--flag", screen.card["path"]]
    assert snapshot(workai) == before


def test_editor_order(monkeypatch):
    monkeypatch.setenv("VISUAL", "code -w")
    monkeypatch.setenv("EDITOR", "nano")
    assert editor_command() == ["code", "-w"]
    monkeypatch.delenv("VISUAL")
    assert editor_command() == ["nano"]
    monkeypatch.delenv("EDITOR")
    assert editor_command() == ["vi"]
