"""Card 01-090: the Waiting column, blocked todo cards sinking and hiding, blocker state in the detail view."""
from __future__ import annotations

import io

from conftest import snapshot, write_card
from rich.console import Console
from test_detail import open_card

from workai_board.app import WorkaiBoard
from workai_board.detail import fields_table, state_text

SIZE = (180, 50)


def labels(app, column):
    return [b.card["label"] for b in app.columns[column].boxes]


def header(app, column):
    return str(app.columns[column].header.content)


async def test_waiting_card_in_waiting_not_doing(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert list(app.columns) == ["todo", "next", "doing", "waiting", "done", "parked"]
        assert labels(app, "waiting") == ["01-006"]
        assert "01-006" not in labels(app, "doing")
        # Non-waiting doing cards (stale 01-007, active 01-008) stay in Doing.
        assert labels(app, "doing") == ["01-007", "01-008"]
        assert header(app, "waiting") == "waiting (1)" and header(app, "doing") == "doing (2)"
        box = app.columns["waiting"].boxes[0]
        assert box.text.plain.split("\n")[1] == "WAIT question for the user"


async def test_card_leaves_waiting_when_answered(workai):
    async with WorkaiBoard(root=workai, poll=0.1).run_test(size=SIZE) as pilot:
        app = pilot.app
        p = workai / "projects/01-alpha/backlog/doing/006-ask-about-colours.md"
        p.write_text(p.read_text().replace("waiting: question for the user", "waiting: "))
        for _ in range(50):
            await pilot.pause(0.1)
            if not labels(app, "waiting"):
                break
        assert labels(app, "waiting") == [] and "01-006" in labels(app, "doing")


async def test_blocked_todo_cards_sink_and_are_dimmed(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        boxes = app.columns["todo"].boxes
        flags = [b.card["flags"]["blocked"] for b in boxes]
        assert flags == sorted(flags)  # every claimable card before every blocked one
        assert labels(app, "todo")[-2:] == ["01-004", "01-005"]
        for b in boxes:
            assert b.has_class("dimmed") == b.card["flags"]["blocked"], b.card["label"]
            assert (b.styles.text_opacity < 1) == b.card["flags"]["blocked"], b.card["label"]
        assert app.columns["todo"].boxes[-1].text.plain.split("\n")[1].startswith("BLOCKED by 01-004")
        # Every sort key and direction keeps them last.
        for key in ("s", "S", "s", "S", "s"):
            await pilot.press(key)
            f = [b.card["flags"]["blocked"] for b in app.columns["todo"].boxes]
            assert f == sorted(f), app.sort_key


async def test_B_hides_and_restores_blocked(workai):
    before = snapshot(workai)
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        await pilot.press("G")  # select the last card, a blocked one
        assert app.selected_card["label"] == "01-005"
        await pilot.press("B")
        assert labels(app, "todo") == ["01-003", "02-002", "02-001"]
        assert header(app, "todo") == "todo (3, 2 blocked hidden)"
        assert "blocked hidden" in str(app.query_one("#status").content)
        assert app.selected_card["label"] == "02-001"  # selection stays in the column
        await pilot.press("B")
        assert labels(app, "todo") == ["01-003", "02-002", "02-001", "01-004", "01-005"]
        assert header(app, "todo") == "todo (5)"
        assert "blocked hidden" not in str(app.query_one("#status").content)
    assert snapshot(workai) == before


async def test_detail_shows_each_blockers_state(workai):
    # 01-010 waits on 01-006 (doing, waiting on the user) and 01-004 (todo, itself blocked).
    write_card(workai, "projects/01-alpha", "todo", "010", "Use the colours", depends="6, 4")
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        screen = await open_card(pilot, "01-010")
        console = Console(width=160, record=True, file=io.StringIO())
        console.print(fields_table(screen.card, None, screen.lookup))
        detail = console.export_text()
        assert "01-006: waiting: question for the user" in detail
        assert "01-004: todo, blocked by 01-003" in detail
        related = "\n".join(str(w.content) for w in screen.query("RelationItem"))
        assert "[waiting: question for the user" in related


def test_state_text_words():
    base = {"project": "01", "flags": {}, "claimed_by": "agent C"}
    assert state_text(None).plain == "missing: no such card"
    assert state_text({**base, "status": "done"}).plain == "done"
    assert state_text({**base, "status": "doing"}).plain == "in progress (agent C)"
    assert state_text({**base, "status": "doing", "flags": {"stale": True}}).plain == "STALE, claimed by agent C"
    assert state_text({**base, "status": "todo", "flags": {"claimable": True}}).plain == "todo, claimable"
