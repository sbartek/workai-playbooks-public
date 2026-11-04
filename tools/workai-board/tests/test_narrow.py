"""Narrow mode (card 01-082): one column at a time below 100 terminal columns."""
from __future__ import annotations

from conftest import snapshot

from workai_board.app import COLUMNS, NARROW_BELOW, WorkaiBoard

PHONE = (60, 30)
WIDE = (160, 50)


def shown(app):
    return [s for s in COLUMNS if app.columns[s].display]


def header(app, s):
    return str(app.columns[s].header.content)


async def test_small_terminal_shows_one_column_full_width(workai):
    async with WorkaiBoard(root=workai).run_test(size=PHONE) as pilot:
        app = pilot.app
        await pilot.pause()
        assert app.narrow and shown(app) == ["todo"]
        assert header(app, "todo") == "  todo (5) >"
        # Full width: the one column takes the screen (minus its 1-cell right margin).
        assert app.columns["todo"].size.width >= PHONE[0] - 2
        assert app.selected_card["label"] == "01-003"


async def test_h_l_switch_the_single_column(workai):
    async with WorkaiBoard(root=workai).run_test(size=PHONE) as pilot:
        app = pilot.app
        await pilot.press("l", "l")
        assert shown(app) == ["doing"] and header(app, "doing") == "< doing (2) >"
        assert app.selected_card["label"] == "01-007"
        await pilot.press("j")
        assert app.selected_card["label"] == "01-008"
        await pilot.press("l", "l")
        assert shown(app) == ["done"] and header(app, "done") == "< done (3) >"
        await pilot.press("l")
        assert shown(app) == ["parked"] and header(app, "parked") == "< parked (0)  "
        await pilot.press("h", "h", "h", "h", "h", "h")
        assert shown(app) == ["todo"]


async def test_resize_back_to_wide_shows_every_column(workai):
    async with WorkaiBoard(root=workai).run_test(size=PHONE) as pilot:
        app = pilot.app
        await pilot.press("l", "l")
        await pilot.resize_terminal(*WIDE)
        await pilot.pause()
        assert not app.narrow and shown(app) == list(COLUMNS)
        assert header(app, "doing") == "doing (2)"
        assert app.current_status == "doing"  # the active column is kept
        await pilot.resize_terminal(NARROW_BELOW - 1, 30)
        await pilot.pause()
        assert shown(app) == ["doing"]


async def test_n_forces_narrow_on_a_wide_terminal(workai):
    before = snapshot(workai)
    async with WorkaiBoard(root=workai).run_test(size=WIDE) as pilot:
        app = pilot.app
        assert shown(app) == list(COLUMNS)
        await pilot.press("n")
        assert shown(app) == ["todo"] and "narrow forced" in str(app.query_one("#status").content)
        await pilot.press("n")
        assert shown(app) == list(COLUMNS)
    assert snapshot(workai) == before
