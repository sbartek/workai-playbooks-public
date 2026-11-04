"""Each project's card border: one of 8 colours x 4 border styles (32 looks).

The assignment is stored, not computed: `<workai>/.workai-board/colours.json`
maps project number -> {"colour": name, "style": name} and is meant to be
hand-editable. A project gets the next free look the first time it has a
card and keeps it for good, so a filter, a search or a hub with no cards
never repaints anything. Handing-out order: the 8 colours in `round`, then
`double`, `heavy`, `dashed`. Projects new in the same load are taken in
number order (hub 01 gets blue on a fresh file). Beyond 32 the looks repeat
from the start; the project number on the card stays the real identity.

This file is the only thing the board writes, and only when a project gets
its first look. A file that cannot be parsed is never overwritten.

Several board sessions may run at once (card 01-113). Handing out looks is
done under an exclusive `flock` on `colours.json.lock`: the file is re-read
inside the lock (another session may have just added a project), the new
looks are written to a unique temp file and moved into place atomically. A
failure to lock or write is reported in `error` and the looks stay in
memory; it never crashes the board.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
from pathlib import Path

# Validated 2026-10-24 (card 01-092) with the dataviz skill's validate_palette.js:
# >= 3:1 contrast on #ffffff, #fcfcfb, #000000 and #1e1e1e; colour-blind safe as a set.
COLOURS = {
    "blue": "#3987e5",
    "orange": "#d95926",
    "aqua": "#199e70",
    "yellow": "#b87a00",
    "magenta": "#d55181",
    "green": "#008300",
    "violet": "#9085e9",
    "red": "#e66767",
}
# Textual border styles that still read apart as thin card edges.
STYLES = ("round", "double", "heavy", "dashed")
ORDER = [(c, s) for s in STYLES for c in COLOURS]  # 32 looks, handing-out order

REL_PATH = Path(".workai-board") / "colours.json"


def path_for(root: Path) -> Path:
    return Path(root) / REL_PATH


class Looks:
    """project number -> (colour name, style name), loaded from and saved to the file."""

    def __init__(self, root: Path) -> None:
        self.path = path_for(root)
        self.map: dict[str, tuple[str, str]] = {}
        self.error = ""  # set when the file exists but cannot be used
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text())
            if not isinstance(raw, dict):
                raise ValueError("not a JSON object")
        except (OSError, ValueError) as e:
            self.error = f"{self.path.name} unreadable ({e}); not saving looks"
            return
        bad = []
        for number, entry in raw.items():
            if isinstance(entry, dict) and entry.get("colour") in COLOURS and entry.get("style") in STYLES:
                self.map[number] = (entry["colour"], entry["style"])
            else:
                bad.append(number)
        if bad:
            self.error = f"{self.path.name}: bad entry for {', '.join(sorted(bad))}; not saving looks"

    def assign(self, projects) -> bool:
        """Give every project without a look the next free one; save if anything changed."""
        wanted = set(projects)
        if not [p for p in wanted if p not in self.map]:
            return False
        if self.error:  # unusable file: hand out in memory only, never overwrite it
            self._hand_out(wanted)
            return True
        before = (dict(self.map), self.error)
        try:
            with self._locked():
                # Re-read inside the lock: another board may have handed out looks.
                self.map, self.error = {}, ""
                self._load()
                new = self._hand_out(wanted)
                if new and not self.error:
                    self._write()
        except OSError as e:
            self.map = before[0]
            self.error = f"cannot save {self.path.name} ({e.strerror or e}); looks kept in memory"
            self._hand_out(wanted)
        return True

    def _hand_out(self, wanted) -> list[str]:
        new = sorted(p for p in wanted if p not in self.map)
        for number in new:
            used = set(self.map.values())
            free = [look for look in ORDER if look not in used]
            self.map[number] = free[0] if free else ORDER[len(self.map) % len(ORDER)]
        return new

    @contextlib.contextmanager
    def _locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        ignore = self.path.parent / ".gitignore"
        if not ignore.exists():  # the lock and temp files never belong in git
            ignore.write_text("# written by workai-board\n*.lock\n*.tmp\n")
        fd = os.open(self.path.with_name(self.path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)  # closing releases the lock

    def save(self) -> None:
        """Write the current map (under the lock). Raises OSError."""
        with self._locked():
            self._write()

    def _write(self) -> None:
        body = {n: {"colour": c, "style": s} for n, (c, s) in sorted(self.map.items())}
        fd, tmp = tempfile.mkstemp(prefix=self.path.name + ".", suffix=".tmp", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as f:
                f.write(json.dumps(body, indent=1) + "\n")
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.path)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise

    def get(self, number: str) -> tuple[str, str] | None:
        return self.map.get(number)

    @property
    def repeated(self) -> int:
        """How many projects share a look with another (only beyond 32 projects, or by hand)."""
        return len(self.map) - len(set(self.map.values()))


def hex_of(look: tuple[str, str] | None) -> str | None:
    return COLOURS[look[0]] if look else None
