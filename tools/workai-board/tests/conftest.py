"""A fixture workai (two project hubs, one archived hub) for the board tests."""
from __future__ import annotations

import hashlib
import os
from datetime import date, timedelta
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
REPORT = REPO / "skills" / "workai-open-project" / "report.py"


def write_card(root: Path, hub: str, status: str, cid: str, title: str, depends: str = "",
               priority: int = 2, body: str = "", **fields) -> Path:
    d = root / hub / "backlog" / status
    d.mkdir(parents=True, exist_ok=True)
    lines = ["---", f"id: {cid}", f'title: "{title}"', "repo: hub", f"priority: {priority}",
             f"depends: [{depends}]"]
    for key in ("claimed_by", "worktree", "branch", "started", "waiting", "finished"):
        lines.append(f"{key}: {fields.get(key, '')}")
    lines += ["---", "## Goal", body or f"Goal of {title}.", "## Done when", "A check.", "## Notes", ""]
    p = d / f"{cid}-{title.lower().replace(' ', '-')}.md"
    p.write_text("\n".join(lines))
    return p


def build_workai(root: Path) -> Path:
    today = date.today().isoformat()
    old = (date.today() - timedelta(days=30)).isoformat()
    a = "projects/01-alpha"
    write_card(root, a, "done", "001", "Lay foundations", priority=1, finished=today)
    write_card(root, a, "done", "002", "Old thing", priority=3, finished=old)
    write_card(root, a, "todo", "003", "Build walls", depends="1", priority=1)
    write_card(root, a, "todo", "004", "Paint walls", depends="3", priority=2)
    write_card(root, a, "todo", "005", "Hang pictures", depends="4, 99", priority=3)
    write_card(root, a, "doing", "006", "Ask about colours", priority=2,
               claimed_by="agent A", waiting="question for the user")
    stale = write_card(root, a, "doing", "007", "Forgotten work", priority=1, claimed_by="agent B")
    os.utime(stale, (1577836800, 1577836800))
    write_card(root, a, "doing", "008", "Active work", priority=2, claimed_by="agent C")
    write_card(root, a, "archive", "009", "Ancient card", finished="2026-01-01")
    b = "projects/02-beta"
    long_body = "\n\n".join(f"Paragraph {i} of a long body." for i in range(60))
    write_card(root, b, "todo", "001", "Beta first", priority=2, body=long_body)
    write_card(root, b, "todo", "002", "Beta second", priority=1)
    write_card(root, b, "done", "003", "Beta done", priority=2, finished=today)
    write_card(root, "archives/03-gamma", "todo", "001", "Gamma archived")
    return root


def snapshot(root: Path) -> dict:
    """Every file except the board's own border-look map (.workai-board/), which it may write."""
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*"))
            if p.is_file() and ".workai-board" not in p.relative_to(root).parts}


@pytest.fixture
def workai(tmp_path, monkeypatch):
    root = build_workai(tmp_path / "workai")
    monkeypatch.setenv("WORKAI_REPORT", str(REPORT))
    monkeypatch.setenv("WORKAI_ROOT", str(root))
    return root
