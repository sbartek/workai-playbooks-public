"""Backlog data for the board: everything comes from report.py --json.

The backlog rules (claimable, blocked, stale, overdue, dependents) live only
in workai-open-project/report.py; this module runs it and never parses a
card itself. Nothing here writes to disk.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPORT_REL = Path("skills") / "workai-open-project" / "report.py"


class ReportError(RuntimeError):
    pass


def default_root() -> Path:
    return Path(os.environ.get("WORKAI_ROOT") or Path.home() / "workai").expanduser()


def find_report(explicit: str | None = None) -> Path:
    """$WORKAI_REPORT, then the repo when installed editable, then the installed skill."""
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get("WORKAI_REPORT"):
        candidates.append(Path(os.environ["WORKAI_REPORT"]).expanduser())
    # Editable install: src/workai_board/data.py -> tools/workai-board -> repo root.
    candidates.append(Path(__file__).resolve().parents[4] / REPORT_REL)
    candidates.append(Path.home() / ".claude" / "skills" / "workai-open-project" / "report.py")
    for c in candidates:
        if c.is_file():
            return c
    raise ReportError("report.py not found; set $WORKAI_REPORT to workai-open-project/report.py")


def hub_dirs(root: Path, archives: bool) -> list[Path]:
    areas = ("projects", "archives") if archives else ("projects",)
    return [p for a in areas for p in sorted((root / a).glob("[0-9][0-9]-*")) if p.is_dir()]


def signature(root: Path, archives: bool) -> tuple:
    """Cheap fingerprint of every card file: re-run the report only when it changes."""
    sig = []
    nxt = root / "next.md"  # the global Next list (report.py reads it)
    try:
        st = nxt.stat()
        sig.append((str(nxt), st.st_mtime_ns, st.st_size))
    except FileNotFoundError:
        sig.append((str(nxt), 0, 0))
    for hub in hub_dirs(root, archives):
        sig.append((str(hub), 0, 0))
        for p in sorted((hub / "backlog").glob("*/[0-9][0-9][0-9]-*.md")):
            try:
                st = p.stat()
            except FileNotFoundError:
                continue
            sig.append((str(p), st.st_mtime_ns, st.st_size))
    return tuple(sig)


def load(root: Path, report: Path, archives: bool = False) -> dict:
    cmd = [sys.executable, str(report), "--json", "--all"]
    if archives:
        cmd.append("--archives")
    cmd.append(str(root))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise ReportError((r.stderr or r.stdout).strip().splitlines()[-1] if (r.stderr or r.stdout).strip() else f"report.py exited {r.returncode}")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        raise ReportError(f"report.py returned invalid JSON: {e}") from e
