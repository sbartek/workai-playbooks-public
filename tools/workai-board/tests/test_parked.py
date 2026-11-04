"""Card 01-179: parked cards (backlog/parked/) get a column of their own, last,
never in todo or next; a card depending on one is blocked; its Next entry is stale."""
from __future__ import annotations

from conftest import snapshot, write_card

from workai_board.app import COLUMNS, WorkaiBoard, column_cards
from workai_board.detail import state_text

SIZE = (200, 50)


def labels(app, column):
    return [b.card["label"] for b in app.columns[column].boxes]


async def test_parked_column_apart_from_todo(workai):
    write_card(workai, "projects/02-beta", "parked", "004", "Beta parked", priority=1)
    write_card(workai, "projects/02-beta", "todo", "005", "After parked", depends="4")
    (workai / "next.md").write_text("# Next\n02-004  # parked\n02-005\n")
    before = snapshot(workai)
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert COLUMNS[-1] == "parked"
        assert labels(app, "parked") == ["02-004"]
        assert str(app.columns["parked"].header.content) == "parked (1)"
        everywhere = {s: labels(app, s) for s in COLUMNS if s != "parked"}
        assert all("02-004" not in v for v in everywhere.values())
        box = app.columns["parked"].boxes[0]
        assert box.text.plain.split("\n")[1].startswith("parked, not now")
        # The dependent is blocked by the parked card and shown in Next as blocked.
        nxt = app.columns["next"].boxes
        assert [b.card["label"] for b in nxt] == ["02-005"]
        assert nxt[0].text.plain.split("\n")[1].startswith("BLOCKED by 02-004")
        assert "stale 02-004 (parked)" in str(app.query_one("#status").content)
    assert snapshot(workai) == before


def test_parked_state_text_and_web_column(workai):
    card = {"label": "02-004", "project": "02", "id": "004", "title": "Beta parked", "status": "parked", "flags": {"parked": True}}
    assert state_text(card).plain == "parked, not now"
    assert column_cards([card], "parked") == [card]
    assert column_cards([card], "todo") == []
