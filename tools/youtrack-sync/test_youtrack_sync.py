"""Tests for youtrack_sync.py against a fake YouTrack (no network, no secret store)."""
from __future__ import annotations

import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import youtrack_sync as ys  # noqa: E402

PROJECTS = {"0-1": {"id": "0-1", "shortName": "H01", "name": "01 Workai Playbooks"},
            "0-2": {"id": "0-2", "shortName": "MM", "name": "03 My Music"}}


class FakeYouTrack:
    """In-memory issues with State, summary and one parent; records every write."""

    def __init__(self):
        self.issues: dict[str, dict] = {}
        self.n = {"0-1": 0, "0-2": 0}
        self.writes: list[tuple] = []
        self.on_board: list[str] = []
        self.aliases = {"WP-2": "H01-2"}           # old id from before a short-name change
        self.states = {pid: {"Todo", "Next", "Doing", "Waiting", "Done", "Parked"} for pid in self.n}
        for summary in ("Board", "Safety"):
            self._new("0-1", summary, "Todo")      # H01-1, H01-2: groups
        self._new("0-2", "Music", "Todo")          # MM-1: another hub's group

    def _new(self, pid, summary, state=""):
        self.n[pid] += 1
        iid = f"{PROJECTS[pid]['shortName']}-{self.n[pid]}"
        self.issues[iid] = {"id": "2-" + iid, "idReadable": iid, "summary": summary, "project": PROJECTS[pid],
                            "state": state, "parent": None}
        return self.issues[iid]

    def _view(self, i):
        return {"id": i["id"], "idReadable": i["idReadable"], "summary": i["summary"], "project": i["project"],
                "customFields": [{"name": "State", "value": {"name": i["state"]} if i["state"] else None}],
                "parent": {"issues": [{"idReadable": i["parent"]}] if i["parent"] else []}}

    def issue(self, iid):
        iid = self.aliases.get(iid, iid)
        return self._view(self.issues[iid]) if iid in self.issues else None

    def state_values(self, pid):
        return self.states.get(pid)

    def project_issues(self, short):
        return [self._view(i) for i in self.issues.values() if i["project"]["shortName"] == short]

    def create_issue(self, pid, summary):
        self.writes.append(("create", summary))
        i = self._new(pid, summary)
        return {"id": i["id"], "idReadable": i["idReadable"]}

    def set_summary(self, iid, summary):
        self.writes.append(("summary", iid, summary))
        self.issues[iid]["summary"] = summary

    def command(self, query, iid):
        self.writes.append(("command", iid, query))
        i = self.issues[iid]
        if query.startswith("State "):
            i["state"] = query[6:]
        elif query.startswith("Type "):
            i["type"] = query[5:]
        elif query.startswith("remove subtask of "):
            if i["parent"] == query[18:]:
                i["parent"] = None
        elif query.startswith("subtask of "):
            i["parent"] = query[11:]
        else:
            raise AssertionError(query)

    def delete_issue(self, iid):
        self.writes.append(("delete", iid))
        del self.issues[iid]

    def boards(self, pid):
        return [{"id": "201-1", "name": "01 Groups", "currentSprint": {"id": "215-2"}},
                {"id": "201-2", "name": "All Cards", "currentSprint": {"id": "215-3"}}] if pid == "0-1" else []

    def add_to_board(self, board, issue_id):
        self.on_board.append((board["name"], issue_id))


def card(root, hub, folder, cid, title, extra=""):
    d = root / "projects" / hub / "backlog" / folder
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{cid}-x.md").write_text(f'---\nid: {cid}\ntitle: "{title}"\ndepends: []\n{extra}---\n## Goal\nsecret body\n')
    return d / f"{cid}-x.md"


class SyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.yt = FakeYouTrack()
        card(self.root, "01-wp", "todo", "001", "Plain todo", "youtrack: H01-1\n")
        card(self.root, "01-wp", "doing", "002", "Working", "youtrack: H01-1\n")
        card(self.root, "01-wp", "doing", "003", "Asked the user", "youtrack: H01-2\nwaiting: question\n")
        card(self.root, "01-wp", "done", "004", "Finished", "youtrack: H01-2\n")
        card(self.root, "01-wp", "todo", "005", "No group")
        card(self.root, "01-wp", "todo", "006", "In next", "youtrack: H01-2\n")
        (self.root / "next.md").write_text("# Next\n01-006  # soon\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_sync(self, **kw):
        out = io.StringIO()
        rc = ys.sync(self.yt, self.root, out=out, **kw)
        return rc, out.getvalue()

    def by_summary(self):
        return {i["summary"]: i for i in self.yt.issues.values()}

    def test_creates_subtasks_with_states_and_parents(self):
        rc, out = self.run_sync()
        self.assertEqual(rc, 0, out)
        s = self.by_summary()
        self.assertEqual((s["01-001 Plain todo"]["state"], s["01-001 Plain todo"]["parent"]), ("Todo", "H01-1"))
        self.assertEqual(s["01-002 Working"]["state"], "Doing")
        self.assertEqual((s["01-003 Asked the user"]["state"], s["01-003 Asked the user"]["parent"]), ("Waiting", "H01-2"))
        self.assertEqual(s["01-004 Finished"]["state"], "Done")
        self.assertEqual(s["01-006 In next"]["state"], "Next")
        self.assertNotIn("01-005 No group", s)
        self.assertEqual({b for b, _ in self.yt.on_board}, {"All Cards"})
        self.assertEqual(len(self.yt.on_board), 5)
        self.assertEqual(s["01-001 Plain todo"].get("type"), "Task")

    def parked_setup(self):
        card(self.root, "01-wp", "parked", "007", "Parked", "youtrack: H01-3\n")
        card(self.root, "01-wp", "done", "008", "Done too", "youtrack: H01-3\n")
        (self.root / "next.md").write_text("# Next\n01-007  # stale: parked\n")
        self.assertEqual(self.yt._new("0-1", "Group three", "Done")["idReadable"], "H01-3")

    def test_parked_card_is_parked_never_next(self):
        self.parked_setup()
        rc, out = self.run_sync()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.by_summary()["01-007 Parked"]["state"], "Parked")
        self.assertEqual(self.yt.issues["H01-3"]["state"], "Parked")  # a parked card keeps its group open
        self.yt.writes.clear()
        self.assertEqual((self.run_sync()[0], self.yt.writes), (0, []))

    def test_parked_falls_back_to_todo_without_the_value(self):
        self.parked_setup()
        self.yt.states["0-1"] = {"Todo", "Next", "Doing", "Waiting", "Done"}
        rc, out = self.run_sync()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.by_summary()["01-007 Parked"]["state"], "Todo")
        self.assertEqual(self.yt.issues["H01-3"]["state"], "Todo")
        self.yt.states["0-1"] = None  # values unreadable: Todo too
        self.yt.writes.clear()
        self.assertEqual((self.run_sync()[0], self.yt.writes), (0, []))

    def test_group_state_is_the_busiest_card(self):
        self.run_sync()
        self.assertEqual(self.yt.issues["H01-1"]["state"], "Doing")
        self.assertEqual(self.yt.issues["H01-2"]["state"], "Waiting")

    def test_second_run_changes_nothing(self):
        self.run_sync()
        self.yt.writes.clear()
        rc, out = self.run_sync()
        self.assertEqual((rc, self.yt.writes), (0, []), out)
        self.assertIn("no change", out)

    def test_dry_run_writes_nothing(self):
        rc, out = self.run_sync(dry_run=True)
        self.assertEqual((rc, self.yt.writes), (0, []))
        self.assertIn("(dry run)", out)

    def test_follows_card_changes(self):
        self.run_sync()
        p = next((self.root / "projects/01-wp/backlog/doing").glob("002-*"))
        text = p.read_text().replace("youtrack: H01-1", "youtrack: H01-2").replace("Working", "Renamed")
        (self.root / "projects/01-wp/backlog/done" / p.name).write_text(text)
        p.unlink()
        self.run_sync()
        i = self.by_summary()["01-002 Renamed"]
        self.assertEqual((i["state"], i["parent"]), ("Done", "H01-2"))
        self.assertEqual(self.yt.issues["H01-1"]["state"], "Todo")
        self.assertEqual(sum(1 for i in self.yt.issues.values() if i["summary"].startswith("01-002")), 1)

    def test_card_leaving_its_group_deletes_its_issue(self):
        self.run_sync()
        p = next((self.root / "projects/01-wp/backlog/todo").glob("001-*"))
        p.write_text(p.read_text().replace("youtrack: H01-1\n", ""))
        self.run_sync()
        self.assertNotIn("01-001 Plain todo", self.by_summary())

    def test_users_own_issues_untouched(self):
        mine = self.yt._new("0-1", "My own note", "Todo")
        self.run_sync()
        self.assertNotIn(mine["idReadable"], [w[1] for w in self.yt.writes if len(w) > 1])
        self.assertIn(mine["idReadable"], self.yt.issues)

    def test_group_in_another_hubs_project_refused(self):
        card(self.root, "01-wp", "todo", "007", "Wrong hub", "youtrack: MM-1\n")
        rc, out = self.run_sync()
        self.assertEqual(rc, 1)
        self.assertIn("REFUSED group MM-1 is in project '03 My Music'", out)
        self.assertNotIn("01-007 Wrong hub", self.by_summary())

    def test_missing_group_and_bad_id_reported(self):
        card(self.root, "01-wp", "todo", "008", "Ghost", "youtrack: H01-99\n")
        card(self.root, "01-wp", "todo", "009", "Bad", "youtrack: five\n")
        rc, out = self.run_sync()
        self.assertEqual(rc, 1)
        self.assertIn("group H01-99 does not exist", out)
        self.assertIn("is not a YouTrack issue id", out)

    def test_old_group_id_is_an_alias(self):
        card(self.root, "01-wp", "todo", "010", "Old id", "youtrack: WP-2\n")
        rc, _ = self.run_sync()
        self.assertEqual(rc, 0)
        self.assertEqual(self.by_summary()["01-010 Old id"]["parent"], "H01-2")
        self.yt.writes.clear()
        self.run_sync()
        self.assertEqual(self.yt.writes, [])

    def test_titles_read_like_report_py(self):
        (self.root / "projects/01-wp/backlog/todo/011-x.md").write_text(
            '---\nid: 011\ntitle: "One \\"All Cards\\" board"  # note\nyoutrack: H01-1\n---\n')
        (self.root / "projects/01-wp/backlog/todo/012-x.md").write_text(
            '---\nid: 012\ntitle: "Title with # inside"\nyoutrack: H01-1\n---\n')
        (self.root / "projects/01-wp/backlog/todo/013-x.md").write_text(
            "---\nid: 013\ntitle: 'Ana''s # list'\nyoutrack: 'H01-1'\n---\n")
        self.run_sync()
        s = self.by_summary()
        self.assertIn('01-011 One "All Cards" board', s)
        self.assertIn("01-012 Title with # inside", s)
        self.assertEqual(s["01-013 Ana's # list"]["parent"], "H01-1")

    def test_card_body_never_leaves(self):
        self.run_sync()
        self.assertFalse(any("secret body" in str(w) for w in self.yt.writes))

    def test_one_hub_only(self):
        card(self.root, "03-music", "todo", "001", "Song", "youtrack: MM-1\n")
        self.run_sync(hub="03")
        s = self.by_summary()
        self.assertIn("03-001 Song", s)
        self.assertNotIn("01-001 Plain todo", s)


if __name__ == "__main__":
    unittest.main()
