"""Board: columns, card lines, navigation, refresh, read-only."""
from __future__ import annotations

from conftest import snapshot, write_card

from workai_board import data
from workai_board.app import WorkaiBoard
from workai_board.cli import parse_args

SIZE = (160, 50)


def labels(app, status):
    return [b.card["label"] for b in app.columns[status].boxes]


def text_of(app, label):
    for col in app.columns.values():
        for b in col.boxes:
            if b.card["label"] == label:
                return b.text.plain
    raise KeyError(label)


async def test_columns_hold_all_hubs_cards(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        # Sorted by priority then project then id; archive/ and archives/ hidden.
        # Claimable first, then the dependency-blocked ones (01-004, 01-005).
        assert labels(app, "todo") == ["01-003", "02-002", "02-001", "01-004", "01-005"]
        assert labels(app, "doing") == ["01-007", "01-008"]
        assert labels(app, "waiting") == ["01-006"]
        assert labels(app, "done") == ["01-001", "02-003", "01-002"]
        assert str(app.columns["todo"].header.content) == "todo (5)"


async def test_archives_option_adds_archived_hubs(workai):
    async with WorkaiBoard(root=workai, archives=True).run_test(size=SIZE) as pilot:
        assert "03-001" in labels(pilot.app, "todo")


async def test_card_lines(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert text_of(app, "01-003").startswith("01-003 Build walls\nclaimable \u00b7 priority: high  ")
        assert "BLOCKED by 01-004, 01-099 (missing) \u00b7 priority: low" in text_of(app, "01-005")
        assert "WAIT question for the user" in text_of(app, "01-006")
        assert "agent A" in text_of(app, "01-006")
        assert text_of(app, "01-007").split("\n")[1].startswith("STALE agent B")
        assert text_of(app, "01-008").split("\n")[1].startswith("agent C")
        assert "overdue for archive" in text_of(app, "01-002")


async def test_navigation(workai):
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        assert app.selected_card["label"] == "01-003"
        assert app.columns["todo"].has_class("active")
        await pilot.press("j", "j")
        assert app.selected_card["label"] == "02-001"
        await pilot.press("k")
        assert app.selected_card["label"] == "02-002"
        await pilot.press("l")
        assert app.current_status == "next" and app.selected_card is None  # no next.md: empty
        await pilot.press("l")
        assert app.current_status == "doing" and app.selected_card["label"] == "01-007"
        assert app.columns["doing"].has_class("active") and not app.columns["todo"].has_class("active")
        await pilot.press("l")
        assert app.current_status == "waiting" and app.selected_card["label"] == "01-006"
        await pilot.press("l")
        assert app.current_status == "done"
        await pilot.press("G")
        assert app.selected_card["label"] == "01-002"
        await pilot.press("h", "h", "h", "h")
        assert app.selected_card["label"] == "02-002"  # todo keeps its row
        await pilot.press("k", "k", "k")
        assert app.selected_card["label"] == "01-003"
        selected = [b.card["label"] for c in app.columns.values() for b in c.boxes if b.has_class("selected")]
        assert selected == ["01-003"]


async def test_auto_refresh_picks_up_changes(workai):
    async with WorkaiBoard(root=workai, poll=0.1).run_test(size=SIZE) as pilot:
        app = pilot.app
        await pilot.press("j")  # select 02-002
        write_card(workai, "projects/02-beta", "todo", "004", "Brand new", priority=1)
        for _ in range(50):
            await pilot.pause(0.1)
            if "02-004" in labels(app, "todo"):
                break
        assert labels(app, "todo")[:3] == ["01-003", "02-002", "02-004"]
        assert app.selected_card["label"] == "02-002"  # selection follows the card


async def test_r_refreshes_by_hand(workai):
    async with WorkaiBoard(root=workai, poll=3600).run_test(size=SIZE) as pilot:
        app = pilot.app
        src = workai / "projects/01-alpha/backlog/todo/003-build-walls.md"
        src.rename(workai / "projects/01-alpha/backlog/doing/003-build-walls.md")
        await pilot.pause()
        assert "01-003" in labels(app, "todo")
        await pilot.press("r")
        await pilot.pause()
        assert "01-003" in labels(app, "doing") and "01-003" not in labels(app, "todo")


async def test_no_reload_when_nothing_changed(workai, monkeypatch):
    calls = []
    real = data.load
    monkeypatch.setattr(data, "load", lambda *a, **k: calls.append(1) or real(*a, **k))
    async with WorkaiBoard(root=workai, poll=0.05).run_test(size=SIZE) as pilot:
        await pilot.pause(0.5)
    assert len(calls) == 1


async def test_report_failure_is_shown(workai, tmp_path):
    bad = tmp_path / "bad.py"
    bad.write_text("import sys; print('boom', file=sys.stderr); sys.exit(3)\n")
    async with WorkaiBoard(root=workai, report=bad).run_test(size=SIZE) as pilot:
        status = str(pilot.app.query_one("#status").content)
        assert "report failed: boom" in status


async def test_session_is_read_only(workai):
    before = snapshot(workai)
    async with WorkaiBoard(root=workai, poll=0.05).run_test(size=SIZE) as pilot:
        await pilot.press("l", "j", "j", "h", "k", "r", "G", "g")
        await pilot.pause(0.3)
    assert snapshot(workai) == before


def test_find_report_prefers_env(workai, monkeypatch, tmp_path):
    other = tmp_path / "report.py"
    other.write_text("")
    monkeypatch.setenv("WORKAI_REPORT", str(other))
    assert data.find_report() == other
    monkeypatch.delenv("WORKAI_REPORT")
    # Running from the repo: falls back to the repo's own report.py.
    assert data.find_report().name == "report.py"


def test_cli_defaults():
    a = parse_args([])
    assert a.root is None and not a.archives


def test_long_blocker_list_is_shortened():
    from workai_board.app import card_text
    card = {"label": "01-010", "project": "01", "id": "010", "title": "T", "status": "todo", "priority": 1,
            "blocked_by": ["001", "002", "003", "004", "005"], "missing": [], "flags": {"blocked": True}, "mtime": 0}
    assert "BLOCKED by 01-001, 01-002, 01-003 +2 more" in card_text(card, 0).plain


async def test_bad_cards_do_not_kill_the_board(workai):
    """Card 01-112: an unreadable card and a duplicate id are warnings, not a dead board."""
    hub = workai / "projects" / "01-alpha" / "backlog"
    (hub / "todo" / "010-dangling.md").symlink_to(hub / "todo" / "nowhere.md")
    (hub / "todo" / "011-latin1.md").write_bytes(b'---\nid: 011\ntitle: "caf\xe9"\ndepends: [02-001]\n---\n')
    write_card(workai, "projects/01-alpha", "todo", "003", "Second three")
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        status = str(app.query_one("#status").content)
        assert "skipped unreadable card" in status and "duplicate card id 01-003" in status
        assert labels(app, "todo").count("01-003") == 2
        assert "BLOCKED by 02-001 (invalid)" in text_of(app, "01-011")


async def test_due_cards_come_first(workai):
    """Card 01-107: due within 14 days or past due on top of its column, blocked or not, marked."""
    from datetime import date, timedelta
    soon = (date.today() + timedelta(days=3)).isoformat()
    past = (date.today() - timedelta(days=1)).isoformat()
    far = (date.today() + timedelta(days=60)).isoformat()
    for p, due in (("todo/005-hang-pictures.md", soon), ("todo/004-paint-walls.md", far),
                   ("doing/008-active-work.md", past)):
        f = workai / "projects" / "01-alpha" / "backlog" / p
        f.write_text(f.read_text().replace("depends:", f"due: {due}\ndepends:", 1))
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        app = pilot.app
        # 01-005 is blocked and priority low, yet first: a deadline never sinks.
        assert labels(app, "todo")[0] == "01-005"
        assert f"due {soon} (3d)" in text_of(app, "01-005")
        # A far date is shown (dim) but does not lift the card.
        assert labels(app, "todo")[-1] == "01-004" and f"due {far} (60d)" in text_of(app, "01-004")
        assert labels(app, "doing")[0] == "01-008" and f"PAST DUE {past}" in text_of(app, "01-008")
        await pilot.press("B")
        assert "01-005" in labels(app, "todo") and "01-004" not in labels(app, "todo")


async def test_old_waiting_card_is_flagged(workai):
    """Card 01-109: a card waiting more than 7 days shows OLD and its age."""
    from datetime import date, timedelta
    f = workai / "projects" / "01-alpha" / "backlog" / "doing" / "006-ask-about-colours.md"
    since = (date.today() - timedelta(days=10)).isoformat()
    f.write_text(f.read_text().replace("finished:", f"waiting_since: {since}\nfinished:", 1))
    async with WorkaiBoard(root=workai).run_test(size=SIZE) as pilot:
        assert "WAIT OLD 10d question for the user" in text_of(pilot.app, "01-006")
        assert "OLD" not in text_of(pilot.app, "01-007")
