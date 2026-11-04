"""Card 01-093: the Next column, from <workai>/next.md through report.py."""
from __future__ import annotations

from conftest import snapshot

from workai_board.app import WorkaiBoard

SIZE = (180, 50)


def labels(app, column):
    return [b.card["label"] for b in app.columns[column].boxes]


def status(app):
    return str(app.query_one("#status").content)


def write_next(root, *lines):
    (root / "next.md").write_text("# Next\n" + "\n".join(lines) + "\n")


async def test_next_column_order_hidden_stale_and_no_duplicates(workai):
    # 01-005 is blocked (by 01-004 and a missing 01-099); 01-006 is in doing/; 01-077 does not exist.
    write_next(workai, "02-001  # quick win", "01-005  # unblock", "01-006", "01-077", "01-004")
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert list(app.columns) == ["todo", "next", "doing", "waiting", "done", "parked"]
        assert labels(app, "next") == ["02-001", "01-005", "01-004"]  # file order, not priority
        assert str(app.columns["next"].header.content) == "next (3/5)"
        assert labels(app, "todo") == ["01-003", "02-002"]  # Next cards are not shown twice
        everywhere = [l for col in app.columns for l in labels(app, col)]
        assert len(everywhere) == len(set(everywhere))
        assert "01-077" not in everywhere and labels(app, "waiting").count("01-006") == 1
        boxes = {b.card["label"]: b for b in app.columns["next"].boxes}
        assert boxes["01-005"].text.plain.split("\n")[1].startswith("BLOCKED by 01-004")
        # The 092 look: same border as the project's other cards.
        todo_01 = next(b for b in app.columns["todo"].boxes if b.card["project"] == "01")
        assert boxes["01-005"].styles.border_top == todo_01.styles.border_top
        assert "stale 01-006 (doing), 01-077 (missing)" in status(app)
        # Sort keys do not reorder Next.
        await pilot.press("s")
        assert labels(app, "next") == ["02-001", "01-005", "01-004"]


async def test_over_cap_warns_and_keeps_all(workai):
    write_next(workai, "02-001", "02-002", "01-003", "01-004", "01-005", "02-001", "01-001")
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert labels(app, "next") == ["02-001", "02-002", "01-003", "01-004", "01-005"]
        assert "over cap" in str(app.columns["next"].header.content)
        assert "next.md has 6 entries; the cap is 5" in status(app)
        assert "listed twice: 02-001" in status(app)


async def test_navigation_filter_and_live_edit(workai):
    async with WorkaiBoard(root=workai, poll=0.1).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert labels(app, "next") == [] and str(app.columns["next"].header.content) == "next (0/5)"
        before = snapshot(workai)
        write_next(workai, "02-002", "01-003")
        for _ in range(50):
            await pilot.pause(0.1)
            if labels(app, "next"):
                break
        assert labels(app, "next") == ["02-002", "01-003"]
        await pilot.press("l")
        assert app.current_status == "next" and app.selected_card["label"] == "02-002"
        await pilot.press("j", "enter")
        await pilot.pause()
        assert app.screen.card["label"] == "01-003"
        await pilot.press("q")
        await pilot.press("slash", "@", "0", "2", "enter")
        assert labels(app, "next") == ["02-002"]
        assert snapshot(workai) == {**before, str(workai / "next.md"): snapshot(workai)[str(workai / "next.md")]}
