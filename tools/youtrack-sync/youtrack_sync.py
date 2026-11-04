#!/usr/bin/env python3
"""One-way sync: backlog cards -> subtasks of their group issues in YouTrack.

A group (the user's word for a larger item; never "epic") is a YouTrack issue,
created and named by hand in the YouTrack project of its hub (a project whose
name starts with the hub number, e.g. "01 Workai Playbooks"). A backlog card
joins it with one frontmatter line, `youtrack: <issue id>` (e.g. H01-5).

For every card with `youtrack:` this script keeps one issue in the group's
project: summary "NN-NNN <card title>", a "subtask of" link to the group,
State from the card (todo/ -> Todo, or Next when the card is in
~/workai/next.md; doing/ -> Doing, or Waiting when `waiting:` is filled;
parked/ -> Parked, never Next (card 01-179; Todo in a project whose State
field has no Parked value); done/ and archive/ -> Done). The group issue
gets the State of its busiest card (Doing > Waiting > Next > Todo > Parked;
Done when all are done). YouTrack then
shows the subtasks and their progress on the group. New card issues get
Type Task; give group issues Type Group, and a board with swimlanes by
issue (Type = Group) would show each group as a row with its cards.

- The card files are the source of truth; nothing is read back into them.
  Only the card label and title leave the backlog, never a card body.
- Issues whose summary does not start with a card label of the hub (NN-NNN)
  are the user's own: never changed. A labelled issue whose card no longer
  has `youtrack:` (or no longer exists) is deleted: the script owns it.
- A group in a project whose name does not start with the card's hub number
  is refused (no hub's cards end up in another hub's project).
- New card issues are put on the project's boards whose name ends in
  "Cards" (the cross-hub "All Cards", the counterpart of workai-board); other boards
  (e.g. "01 Groups" with only the group issues) are left alone.
- Running it twice changes nothing the second time.

Usage:
  youtrack_sync.py [--root ~/workai] [--hub 01] [--dry-run] [--url URL]

The API token is read at run time with `workai-secret get youtrack/api`
(card 146), never from an argument or a file. The URL defaults to
http://127.0.0.1:8645 (YOUTRACK_URL overrides it).
"""
from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_URL = "http://127.0.0.1:8645"
SECRET = "youtrack/api"
LABEL_RE = re.compile(r"^(\d{2}-\d{3})\b")
HUB_RE = re.compile(r"^(\d{2})-")
CARD_RE = re.compile(r"^(\d{3})-.*\.md$")
ISSUE_RE = re.compile(r"^[A-Z][A-Z0-9_]*-\d+$")
FOLDERS = ("todo", "doing", "parked", "done", "archive")
BUSIEST = ("Doing", "Waiting", "Next", "Todo", "Parked")
PARKED, PARKED_FALLBACK = "Parked", "Todo"  # a project without a Parked State gets Todo


class SyncError(RuntimeError):
    pass


# --- the backlog side --------------------------------------------------------

@dataclass(frozen=True)
class Card:
    label: str      # "01-078"
    title: str
    state: str      # Todo, Next, Doing, Waiting, Parked, Done
    group: str      # "H01-5"
    path: Path

    @property
    def summary(self) -> str:
        return f"{self.label} {self.title}"


def _report():
    """skills/workai-open-project/report.py, whose card parser workai-board also
    uses: one parser, so YouTrack and the board never read a title differently."""
    path = Path(__file__).resolve().parents[2] / "skills" / "workai-open-project" / "report.py"
    spec = importlib.util.spec_from_file_location("workai_report", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


REPORT = _report()


def frontmatter(text: str) -> dict:
    return REPORT.parse_card(text)[0]


def hub_dirs(root: Path, hub: str | None) -> list[Path]:
    hubs = sorted(d for d in (root / "projects").glob("[0-9][0-9]-*") if d.is_dir())
    return [d for d in hubs if hub is None or d.name.startswith(f"{int(hub):02d}-")]


def next_labels(root: Path) -> set[str]:
    try:
        text = (root / "next.md").read_text()
    except OSError:
        return set()
    return {m.group(1) for m in (LABEL_RE.match(l.strip()) for l in text.splitlines()) if m}


def card_state(folder: str, fields: dict, label: str, nxt: set[str]) -> str:
    if folder in ("done", "archive"):
        return "Done"
    if folder == "doing":
        return "Waiting" if fields.get("waiting", "").strip() else "Doing"
    if folder == "parked":  # a Next line for it is stale, so never Next
        return PARKED
    return "Next" if label in nxt else "Todo"


def read_cards(hub_dir: Path, nxt: set[str]) -> tuple[list[Card], list[str]]:
    """Cards of one hub that carry `youtrack:`, and problems found on the way."""
    number = HUB_RE.match(hub_dir.name).group(1)
    cards, problems = [], []
    for folder in FOLDERS:
        for path in sorted((hub_dir / "backlog" / folder).glob("[0-9][0-9][0-9]-*.md")):
            m = CARD_RE.match(path.name)
            if not m:
                continue
            try:
                fields = frontmatter(path.read_text())
            except OSError as e:
                problems.append(f"{path}: unreadable ({e})")
                continue
            raw = fields.get("youtrack", "")
            if not raw:
                continue
            if not ISSUE_RE.match(raw):
                problems.append(f"{path.name}: youtrack: {raw!r} is not a YouTrack issue id")
                continue
            label = f"{number}-{m.group(1)}"
            title = fields.get("title", "").strip() or path.stem[4:].replace("-", " ")
            cards.append(Card(label, title, card_state(folder, fields, label, nxt), raw, path))
    return cards, problems


def group_state(cards: list[Card]) -> str:
    states = {c.state for c in cards}
    return next((s for s in BUSIEST if s in states), "Done")


# --- the YouTrack side -------------------------------------------------------

ISSUE_FIELDS = "id,idReadable,summary,project(id,shortName,name),customFields(name,value(name)),parent(issues(idReadable))"


class YouTrackAPI:
    """The few REST calls the sync needs. `call` is the only network code."""

    def __init__(self, url: str, token: str, timeout: float = 30) -> None:
        self.url, self.timeout = url.rstrip("/") + "/api", timeout
        self._headers = {"Authorization": "Bearer " + token, "Accept": "application/json",
                         "Content-Type": "application/json"}

    def call(self, method: str, path: str, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method, headers=self._headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            detail = e.read()[:200].decode(errors="replace")
            raise SyncError(f"YouTrack {method} {path.split('?')[0]}: HTTP {e.code}"
                            + (" (wrong token?)" if e.code == 401 else f" {detail}")) from None
        except (urllib.error.URLError, OSError) as e:
            raise SyncError(f"YouTrack not reachable at {self.url}: {e}") from None
        return json.loads(text) if text else None

    def issue(self, id_readable: str) -> dict | None:
        return self.call("GET", f"/issues/{id_readable}?fields={ISSUE_FIELDS}")

    def project_issues(self, short_name: str) -> list[dict]:
        q = urllib.parse.quote(f"project: {short_name}")
        return self.call("GET", f"/issues?query={q}&fields={ISSUE_FIELDS}&$top=2000") or []

    def create_issue(self, project_id: str, summary: str) -> dict:
        return self.call("POST", "/issues?fields=id,idReadable",
                         {"project": {"id": project_id}, "summary": summary})

    def set_summary(self, id_readable: str, summary: str) -> None:
        self.call("POST", f"/issues/{id_readable}", {"summary": summary})

    def command(self, query: str, id_readable: str) -> None:
        self.call("POST", "/commands", {"query": query, "issues": [{"idReadable": id_readable}]})

    def delete_issue(self, id_readable: str) -> None:
        self.call("DELETE", f"/issues/{id_readable}")

    def state_values(self, project_id: str) -> set[str] | None:
        """Names of the project's State values, or None when they cannot be read."""
        try:
            fields = self.call("GET", f"/admin/projects/{project_id}/customFields"
                                      "?fields=field(name),bundle(values(name))&$top=100") or []
        except SyncError:
            return None
        for f in fields:
            if (f.get("field") or {}).get("name") == "State":
                return {v.get("name") for v in (f.get("bundle") or {}).get("values") or []}
        return None

    def boards(self, project_id: str) -> list[dict]:
        agiles = self.call("GET", "/agiles?fields=id,name,projects(id),currentSprint(id)&$top=200") or []
        return [a for a in agiles if any(p.get("id") == project_id for p in a.get("projects") or [])]

    def add_to_board(self, board: dict, issue_id: str) -> None:
        sprint = (board.get("currentSprint") or {}).get("id")
        if sprint:
            self.call("POST", f"/agiles/{board['id']}/sprints/{sprint}/issues", {"id": issue_id, "$type": "Issue"})


def state_of(issue: dict) -> str:
    for f in issue.get("customFields") or []:
        if f.get("name") == "State":
            return (f.get("value") or {}).get("name", "")
    return ""


def parents_of(issue: dict) -> list[str]:
    return [i["idReadable"] for i in ((issue.get("parent") or {}).get("issues") or [])]


def token() -> str:
    try:
        r = subprocess.run(["workai-secret", "get", SECRET], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SyncError(f"cannot run workai-secret: {e}") from None
    if r.returncode != 0 or not r.stdout.strip():
        raise SyncError(f"no YouTrack token (workai-secret set {SECRET})")
    return r.stdout.strip()


# --- the sync ----------------------------------------------------------------

@dataclass
class Plan:
    """What one hub needs, as (action, issue or label, detail) steps in order."""
    steps: list = field(default_factory=list)
    lines: list = field(default_factory=list)  # report, one per group


def plan_hub(api, number: str, cards: list[Card]) -> tuple[Plan, list[str]]:
    plan, refused = Plan(), []
    groups: dict[str, list[Card]] = {}
    for c in cards:
        groups.setdefault(c.group, []).append(c)
    projects: dict[str, dict] = {}   # project id -> project, for every group project of this hub
    group_issue: dict[str, dict] = {}
    for gid in sorted(groups):
        g = api.issue(gid)
        named = ", ".join(c.label for c in groups[gid])
        if not g:
            refused.append(f"group {gid} does not exist in YouTrack (named by {named})")
            continue
        pname = g["project"].get("name", "")
        if not pname.startswith(f"{number} "):
            refused.append(f"group {gid} is in project {pname!r}, not a project of hub {number}; cards {named} were not synced")
            continue
        projects[g["project"]["id"]] = g["project"]
        # An old id (WP-5 after the project became H01) is an alias: use the
        # issue's current id, or every run would relink its cards.
        canon = g.get("idReadable") or gid
        if canon != gid:
            groups.setdefault(canon, []).extend(groups.pop(gid))
        group_issue[canon] = g
    # Parked needs a Parked State value in the project; without one it is Todo.
    values = {pid: api.state_values(pid) for pid in projects}
    for gid, g in group_issue.items():
        if PARKED not in (values.get(g["project"]["id"]) or set()):
            groups[gid] = [dataclasses.replace(c, state=PARKED_FALLBACK) if c.state == PARKED else c
                           for c in groups[gid]]
    # Every labelled issue of this hub in those projects, by label.
    existing: dict[str, list[dict]] = {}
    for p in projects.values():
        for i in api.project_issues(p["shortName"]):
            m = LABEL_RE.match(i.get("summary", ""))
            if m and m.group(1).startswith(f"{number}-"):
                existing.setdefault(m.group(1), []).append(i)
    wanted = {c.label: c for gid in group_issue for c in groups[gid]}
    for label, issues in sorted(existing.items()):
        keep = issues[0] if label in wanted else None
        for i in issues:
            if i is not keep:  # card left its group or is gone, or a duplicate
                plan.steps.append(("delete", i["idReadable"], label))
    for gid, g in sorted(group_issue.items()):
        n = {"create": 0, "update": 0}
        for c in sorted(groups[gid], key=lambda c: c.label):
            have = (existing.get(c.label) or [None])[0]
            if have is None:
                plan.steps.append(("create", c, g["project"]["id"], gid))
                n["create"] += 1
                continue
            iid, changed = have["idReadable"], False
            if have.get("summary") != c.summary:
                plan.steps.append(("summary", iid, c.summary)); changed = True
            if state_of(have) != c.state:
                plan.steps.append(("command", iid, f"State {c.state}")); changed = True
            for old in parents_of(have):
                if old != gid:
                    plan.steps.append(("command", iid, f"remove subtask of {old}")); changed = True
            if gid not in parents_of(have):
                plan.steps.append(("command", iid, f"subtask of {gid}")); changed = True
            n["update"] += changed
        gs = group_state(groups[gid])
        if state_of(g) != gs:
            plan.steps.append(("command", gid, f"State {gs}"))
        done = sum(1 for c in groups[gid] if c.state == "Done")
        what = f"+{n['create']} ~{n['update']}" if n["create"] or n["update"] else "no change"
        plan.lines.append(f"  {gid} {g.get('summary', '')!r}: {done}/{len(groups[gid])} done, State {gs}; {what}")
    deletes = sum(1 for s in plan.steps if s[0] == "delete")
    if deletes:
        plan.lines.append(f"  -{deletes} issue(s) whose card left its group")
    return plan, refused


def apply(api, plan: Plan) -> None:
    boards: dict[str, list[dict]] = {}
    for step in plan.steps:
        action = step[0]
        if action == "delete":
            api.delete_issue(step[1])
        elif action == "summary":
            api.set_summary(step[1], step[2])
        elif action == "command":
            api.command(step[2], step[1])
        elif action == "create":
            card, project_id, gid = step[1], step[2], step[3]
            new = api.create_issue(project_id, card.summary)
            api.command("Type Task", new["idReadable"])
            api.command(f"State {card.state}", new["idReadable"])
            api.command(f"subtask of {gid}", new["idReadable"])
            if project_id not in boards:
                boards[project_id] = [b for b in api.boards(project_id)
                                      if str(b.get("name", "")).endswith("Cards")]
            for b in boards[project_id]:
                api.add_to_board(b, new["id"])


def sync(api, root: Path, hub: str | None = None, dry_run: bool = False, out=sys.stdout) -> int:
    """Sync every hub (or one). Returns the exit code: 0 ok, 1 some group refused or a card problem."""
    rc = 0
    nxt = next_labels(root)
    for hub_dir in hub_dirs(root, hub):
        number = HUB_RE.match(hub_dir.name).group(1)
        cards, problems = read_cards(hub_dir, nxt)
        if not cards and not problems:
            continue
        print(f"{hub_dir.name}:", file=out)
        for p in problems:
            print(f"  problem: {p}", file=out)
            rc = 1
        plan, refused = plan_hub(api, number, cards)
        for r in refused:
            print(f"  REFUSED {r}", file=out)
            rc = 1
        for line in plan.lines:
            print(line + (" (dry run)" if dry_run and plan.steps and "no change" not in line else ""), file=out)
        if not dry_run:
            apply(api, plan)
    return rc


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--root", default=os.environ.get("WORKAI_ROOT", str(Path.home() / "workai")))
    p.add_argument("--hub", help="only this hub number, e.g. 01")
    p.add_argument("--dry-run", action="store_true", help="show what would change, change nothing")
    p.add_argument("--url", default=os.environ.get("YOUTRACK_URL", DEFAULT_URL))
    args = p.parse_args(argv)
    try:
        api = YouTrackAPI(args.url, token())
        return sync(api, Path(args.root).expanduser(), args.hub, args.dry_run)
    except SyncError as e:
        print(f"youtrack-sync: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
