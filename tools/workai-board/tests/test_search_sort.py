"""Search (live filter, Enter keeps, Esc clears) and sort (s cycles, S reverses)."""
from __future__ import annotations

from workai_board.app import WorkaiBoard
from workai_board.query import matches

SIZE = (160, 50)


def board(app):
    # No next.md in the fixture: the Next column stays empty and is left out here.
    return {s: [b.card["label"] for b in col.boxes] for s, col in app.columns.items() if s not in ("next", "parked")}


async def search(pilot, text):
    await pilot.press("slash", *list(text))
    await pilot.pause()


async def test_live_filter_on_title(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        await search(pilot, "wal")
        assert board(app) == {"todo": ["01-003", "01-004"], "doing": [], "waiting": [], "done": []}
        await pilot.press("l")  # still typing: no navigation, the letter goes to the search
        await pilot.pause()
        assert app.filter == "wall" and board(app)["todo"] == ["01-003", "01-004"]


async def test_filter_by_id(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await search(pilot, "#01-003")
        assert board(pilot.app) == {"todo": ["01-003"], "doing": [], "waiting": [], "done": []}
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await search(pilot, "#003")
        assert board(pilot.app) == {"todo": ["01-003"], "doing": [], "waiting": [], "done": ["02-003"]}
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await search(pilot, "#00")
        assert len(sum(board(pilot.app).values(), [])) == 11


async def test_filter_by_project(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await search(pilot, "@02")
        assert board(pilot.app) == {"todo": ["02-002", "02-001"], "doing": [], "waiting": [], "done": ["02-003"]}
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        await search(pilot, "#01- work")
        assert board(pilot.app) == {"todo": [], "doing": ["01-007", "01-008"], "waiting": [], "done": []}


async def test_enter_keeps_filter_and_esc_clears(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        await search(pilot, "@01")
        await pilot.press("enter")
        await pilot.pause()
        assert not app.query_one("#search").has_class("visible")
        assert app.filter == "@01"
        assert "filter '@01'" in str(app.query_one("#status").content)
        await pilot.press("j")  # keys drive the board again
        assert app.selected_card["label"] == "01-004"
        assert board(app)["todo"] == ["01-003", "01-004", "01-005"]
        await pilot.press("slash")  # reopening shows the kept filter
        assert app.query_one("#search").value == "@01"
        await pilot.press("escape")
        await pilot.pause()
        assert app.filter == "" and len(board(app)["todo"]) == 5
        assert not app.query_one("#search").has_class("visible")


async def test_esc_on_board_clears_a_kept_filter(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        await search(pilot, "beta")
        await pilot.press("enter", "escape")
        await pilot.pause()
        assert app.filter == "" and len(board(app)["todo"]) == 5


async def test_sort_keys_cycle_and_reverse(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert app.sort_key == "priority"
        assert board(app)["todo"] == ["01-003", "02-002", "02-001", "01-004", "01-005"]  # blocked last
        assert board(app)["done"] == ["01-001", "02-003", "01-002"]
        await pilot.press("s")
        assert app.sort_key == "id"
        assert board(app)["todo"] == ["02-001", "02-002", "01-003", "01-004", "01-005"]
        await pilot.press("s")
        assert app.sort_key == "finished"
        assert board(app)["done"] == ["01-002", "01-001", "02-003"]  # oldest first
        await pilot.press("S")
        assert board(app)["done"] == ["02-003", "01-001", "01-002"]  # newest first
        await pilot.press("S", "s")
        assert app.sort_key == "project"
        assert board(app)["todo"] == ["01-003", "02-002", "02-001", "01-004", "01-005"]
        await pilot.press("S")
        assert board(app)["todo"] == ["02-001", "02-002", "01-003", "01-005", "01-004"]  # blocked stay last
        assert "sort project desc" in str(app.query_one("#status").content)
        await pilot.press("S", "s")
        assert app.sort_key == "priority"
        assert board(app)["todo"] == ["01-003", "02-002", "02-001", "01-004", "01-005"]


async def test_sort_keeps_selected_card(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        await pilot.press("j")
        assert app.selected_card["label"] == "02-002"
        await pilot.press("s")
        assert app.selected_card["label"] == "02-002"


def test_matches_terms():
    card = {"label": "01-009", "project": "01", "id": "009", "title": "Review Coches"}
    assert matches(card, "coches") and matches(card, "#01-009") and matches(card, "#009")
    assert matches(card, "@1") and matches(card, "@01 review") and matches(card, "")
    assert not matches(card, "@02") and not matches(card, "#02-") and not matches(card, "review taxes")
