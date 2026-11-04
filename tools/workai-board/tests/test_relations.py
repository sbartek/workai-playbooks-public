"""Dependency navigation: walk a chain forward and back, q to the board."""
from __future__ import annotations

from conftest import snapshot, write_card
from test_detail import open_card

from workai_board.app import WorkaiBoard
from workai_board.detail import DetailScreen, RelationItem


def related(screen):
    return [(i.kind, i.label) for i in screen.query(RelationItem)]


def focused_label(screen):
    return screen.focused.label if isinstance(screen.focused, RelationItem) else None


def depth(app):
    return sum(isinstance(s, DetailScreen) for s in app.screen_stack)


async def test_walk_chain_forward_and_back(workai):
    before = snapshot(workai)
    async with WorkaiBoard(root=workai).run_test(size=(120, 30)) as pilot:
        app = pilot.app
        s3 = await open_card(pilot, "01-003")
        assert related(s3) == [("depends on", "01-001"), ("needed by", "01-004")]
        await pilot.press("tab")
        assert focused_label(s3) == "01-001"
        await pilot.press("tab")
        assert focused_label(s3) == "01-004"
        await pilot.press("tab")  # wraps
        assert focused_label(s3) == "01-001"
        await pilot.press("shift+tab")
        assert focused_label(s3) == "01-004"
        await pilot.press("enter")
        await pilot.pause()
        s4 = app.screen
        assert s4.card["label"] == "01-004" and depth(app) == 2
        assert related(s4) == [("depends on", "01-003"), ("needed by", "01-005")]
        await pilot.press("tab", "tab", "enter")
        await pilot.pause()
        s5 = app.screen
        assert s5.card["label"] == "01-005" and depth(app) == 3
        # Missing ids are shown, not hidden, and cannot be opened.
        assert related(s5) == [("depends on", "01-004"), ("depends on", "01-099")]
        missing = s5.query(RelationItem)[1]
        assert missing.target is None and "missing" in str(missing.content)
        await pilot.press("tab", "tab", "enter")
        await pilot.pause()
        assert app.screen is s5 and focused_label(s5) == "01-099"
        # Back one step at a time, focus restored.
        await pilot.press("escape")
        await pilot.pause()
        assert app.screen is s4 and focused_label(s4) == "01-005"
        await pilot.press("backspace")
        await pilot.pause()
        assert app.screen is s3 and focused_label(s3) == "01-004"
        # Forward again into the depends-on side, then back.
        await pilot.press("shift+tab", "enter")
        await pilot.pause()
        assert app.screen.card["label"] == "01-001"
        assert related(app.screen) == [("needed by", "01-003")]
        await pilot.press("escape")
        await pilot.pause()
        assert app.screen is s3 and focused_label(s3) == "01-001"
        await pilot.press("escape")
        await pilot.pause()
        assert depth(app) == 0 and app.selected_card["label"] == "01-003"
    assert snapshot(workai) == before


async def test_back_restores_scroll(workai):
    long = "\n\n".join(f"Line {i}." for i in range(40))
    write_card(workai, "projects/02-beta", "todo", "010", "Long parent", body=long)
    write_card(workai, "projects/02-beta", "todo", "011", "Child", depends="10")
    async with WorkaiBoard(root=workai).run_test(size=(100, 20)) as pilot:
        app = pilot.app
        s = await open_card(pilot, "02-010")
        await pilot.press("tab")
        assert focused_label(s) == "02-011"
        await pilot.press("j", "j", "j", "j", "j")
        await pilot.pause()
        y = s.viewport.scroll_y
        assert y > 0
        await pilot.press("enter")
        await pilot.pause()
        assert app.screen.card["label"] == "02-011"
        await pilot.press("G")
        await pilot.press("escape")
        await pilot.pause(0.1)
        assert app.screen is s and s.viewport.scroll_y == y and focused_label(s) == "02-011"


async def test_q_returns_to_board_keeping_search_and_sort(workai):
    async with WorkaiBoard(root=workai).run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.press("slash", "@", "0", "1", "enter", "s")
        await pilot.pause()
        assert app.filter == "@01" and app.sort_key == "id"
        await open_card(pilot, "01-004")
        await pilot.press("tab", "enter")
        await pilot.pause()
        await pilot.press("tab", "enter")
        await pilot.pause()
        assert depth(app) == 3
        await pilot.press("q")
        await pilot.pause()
        assert depth(app) == 0
        assert app.filter == "@01" and app.sort_key == "id"
        assert app.selected_card["label"] == "01-004"
        assert [b.card["label"] for b in app.columns["todo"].boxes] == ["01-003", "01-004", "01-005"]


async def test_archived_dependency_opens(workai):
    write_card(workai, "projects/01-alpha", "todo", "012", "Needs ancient", depends="9")
    async with WorkaiBoard(root=workai).run_test(size=(120, 30)) as pilot:
        s = await open_card(pilot, "01-012")
        assert related(s) == [("depends on", "01-009")]
        await pilot.press("tab", "enter")
        await pilot.pause()
        assert pilot.app.screen.card["status"] == "archive"
