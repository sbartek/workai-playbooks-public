"""Card 01-092: border = project look (colour x style, stored map), flags as text,
selection by tint + marker, priority as a word on line 2."""
from __future__ import annotations

import io
import json

from conftest import write_card
from textual.color import Color

from workai_board import looks
from workai_board.app import WorkaiBoard, card_text
from workai_board.detail import DetailScreen, fields_table

SIZE = (160, 50)
RED = Color.parse("#ff0000")


def boxes(app):
    return {b.card["label"]: b for c in app.columns.values() for b in c.boxes}


def border(box):
    style, colour = box.styles.border_top
    return style, colour.hex.lower()


def stored(root):
    return json.loads(looks.path_for(root).read_text())


def expect(look):
    return look[1], looks.COLOURS[look[0]]


async def test_border_is_the_stored_look_of_the_project(workai):
    path = looks.path_for(workai)
    path.parent.mkdir()
    path.write_text(json.dumps({"01": {"colour": "violet", "style": "dashed"}}))
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        # 02 had no look: it gets the first free one in handing-out order.
        assert stored(workai) == {"01": {"colour": "violet", "style": "dashed"},
                                  "02": {"colour": "blue", "style": "round"}}
        for label, box in boxes(app).items():
            entry = stored(workai)[label[:2]]
            assert border(box) == (entry["style"], looks.COLOURS[entry["colour"]]), label


async def test_new_hub_gets_next_free_look_and_keeps_it(workai):
    async with WorkaiBoard(root=workai, poll=0.1).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert stored(workai) == {"01": {"colour": "blue", "style": "round"},
                                  "02": {"colour": "orange", "style": "round"}}
        write_card(workai, "projects/00-zero", "todo", "001", "Zero card", priority=1)
        for _ in range(50):
            await pilot.pause(0.1)
            if "00-001" in boxes(app):
                break
        # The newcomer is numbered lower but takes the next FREE look; nothing repaints.
        assert stored(workai)["00"] == {"colour": "aqua", "style": "round"}
        assert border(boxes(app)["00-001"]) == ("round", looks.COLOURS["aqua"])
        assert border(boxes(app)["01-003"]) == ("round", looks.COLOURS["blue"])
    before = stored(workai)
    (workai / "projects/01-alpha/backlog").rename(workai / "projects/01-alpha/gone")  # 01 has no cards now
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        assert stored(workai) == before  # restart: same looks, a hub without cards keeps its look
        assert border(boxes(pilot.app)["00-001"]) == ("round", looks.COLOURS["aqua"])


async def test_hub_without_cards_gets_no_look(workai):
    (workai / "projects/05-empty/backlog/todo").mkdir(parents=True)
    async with WorkaiBoard(root=workai).run_test(size=SIZE):
        assert "05" not in stored(workai)


async def test_filter_never_changes_a_look(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        before = {k: border(b) for k, b in boxes(app).items()}
        file_before = looks.path_for(workai).read_text()
        await pilot.press("slash", "@", "0", "2")
        assert set(boxes(app)) == {"02-001", "02-002", "02-003"}
        assert all(border(b) == before[k] for k, b in boxes(app).items())
        await pilot.press("escape")
        assert {k: border(b) for k, b in boxes(app).items()} == before
        assert looks.path_for(workai).read_text() == file_before


async def test_blocked_and_wait_have_text_flag_not_red_border(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        b = boxes(pilot.app)
        for label in ("01-005", "01-006"):
            style, colour = b[label].styles.border_top
            assert colour != RED and border(b[label]) == border(b["01-003"]), label
        assert b["01-005"].text.plain.split("\n")[1].startswith("BLOCKED by ")
        assert b["01-006"].text.plain.split("\n")[1].startswith("WAIT question for the user")


async def test_selected_card_has_tint_and_marker(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        b = boxes(pilot.app)
        sel, other = b["01-003"], b["02-002"]
        assert sel.has_class("selected") and not other.has_class("selected")
        assert sel.styles.background != other.styles.background and sel.styles.background.a > 0
        assert str(sel.content).startswith("▶ 01-003 Build walls")
        assert str(other.content).startswith("02-002 Beta second")
        assert border(sel) == border(b["01-004"])  # selection does not touch the border
        await pilot.press("j")
        b = boxes(pilot.app)
        assert not str(b["01-003"].content).startswith("▶") and str(b["02-002"].content).startswith("▶ 02-002")


async def test_priority_word_on_line_two_and_never_pN(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        b = boxes(app)
        line2 = {k: box.text.plain.split("\n")[1] for k, box in b.items()}
        assert "claimable · priority: high" in line2["01-003"]          # todo
        assert "priority: normal" in line2["01-008"]                          # doing
        # A waiting card: the question on line 2, holder and priority on line 3.
        assert line2["01-006"].startswith("WAIT ") and "priority: normal" in b["01-006"].text.plain.split("\n")[2]
        assert "STALE agent B · priority: high" in line2["01-007"]
        assert "priority: low" in line2["01-002"] and line2["01-002"].startswith("overdue")  # done
        assert {w for v in line2.values() for w in ("high", "normal", "low") if f"priority: {w}" in v} == {"high", "normal", "low"}
        texts = [box.text.plain for box in b.values()]
        # Detail view of a card with relations, rendered.
        await pilot.press("j", "j", "j")  # 01-004: depends on 01-003, needed by 01-005
        await pilot.press("enter")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, DetailScreen)
        rendered = "\n".join(str(w.content) for w in screen.query("RelationItem"))
        from rich.console import Console
        console = Console(width=120, record=True, file=io.StringIO())
        console.print(fields_table(screen.card, screen.look_of(screen.card["project"])))
        detail = console.export_text()
        assert "Priority       normal" in detail
        assert "Border         ╭── blue, round" in detail
        assert "[todo, claimable · priority: high]" in rendered
        assert "[todo, blocked by 01-004, 01-099 · priority: low]" in rendered
        for t in texts + [detail, rendered]:
            for bad in (" p1", " p2", " p3", "p1 ", "p2 ", "p3 "):
                assert bad not in t


def test_missing_priority_and_long_wait():
    card = {"label": "01-010", "project": "01", "id": "010", "title": "T", "status": "doing", "priority": None,
            "claimed_by": "agent Z", "waiting": "x" * 200, "flags": {"waiting": True}, "mtime": 0}
    lines = card_text(card, 0).plain.split("\n")
    # 01-090: the Waiting column is for reading, so far more than the old 40 characters...
    assert lines[1] == "WAIT " + "x" * 200
    # ...on a line of its own, so holder and priority still show below it.
    assert "priority: ?" in lines[2] and lines[2].startswith("agent Z")


def test_handing_out_order_and_reuse_beyond_32(tmp_path):
    lk = looks.Looks(tmp_path)
    lk.assign(f"{n:02d}" for n in range(1, 34))
    assert lk.get("01") == ("blue", "round") and lk.get("08") == ("red", "round")
    assert lk.get("09") == ("blue", "double") and lk.get("17") == ("blue", "heavy")
    assert lk.get("32") == ("red", "dashed") and lk.get("33") == ("blue", "round")
    assert lk.repeated == 1
    assert looks.Looks(tmp_path).map == lk.map  # saved


def test_unreadable_file_is_never_overwritten(tmp_path):
    p = looks.path_for(tmp_path)
    p.parent.mkdir()
    p.write_text("{not json")
    lk = looks.Looks(tmp_path)
    lk.assign(["01"])
    assert p.read_text() == "{not json" and lk.error and lk.get("01") == ("blue", "round")


def test_parallel_writers_leave_valid_json_and_distinct_looks(tmp_path):
    """Card 01-113: several board sessions handing out looks at once."""
    import threading

    workers, each = 8, 4  # 32 projects = exactly the 32 looks
    start = threading.Barrier(workers)
    errors = []

    def board(w):
        try:
            start.wait()
            for i in range(each):
                lk = looks.Looks(tmp_path)  # a fresh load per reload, as the app does
                lk.assign([f"{w * each + i + 1:02d}"])
                assert not lk.error, lk.error
        except Exception as e:  # noqa: BLE001 - any crash fails the test
            errors.append(repr(e))

    threads = [threading.Thread(target=board, args=(w,)) for w in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    data = stored(tmp_path)  # valid JSON
    assert sorted(data) == [f"{n:02d}" for n in range(1, 33)]  # nobody's project lost
    assert len({(e["colour"], e["style"]) for e in data.values()}) == 32  # no look given twice
    leftovers = [p.name for p in looks.path_for(tmp_path).parent.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == []


def test_unwritable_folder_does_not_crash(tmp_path):
    folder = looks.path_for(tmp_path).parent
    folder.mkdir()
    folder.chmod(0o555)
    try:
        lk = looks.Looks(tmp_path)
        assert lk.assign(["01"]) is True  # no exception
        assert lk.get("01") == ("blue", "round") and "cannot save" in lk.error
        assert not looks.path_for(tmp_path).exists()
    finally:
        folder.chmod(0o755)


def test_lock_and_temp_files_are_git_ignored(tmp_path):
    looks.Looks(tmp_path).assign(["01"])
    ignore = (looks.path_for(tmp_path).parent / ".gitignore").read_text().split()
    assert "*.lock" in ignore and "*.tmp" in ignore and "colours.json" not in ignore
