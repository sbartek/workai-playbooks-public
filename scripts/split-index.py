#!/usr/bin/env python3
"""Before the hand-kept workai index is replaced by the generated one, keep each
project's old entry inside its own hub, so no state is lost.

Usage: scripts/split-index.py [--write] [WORKAI_ROOT]
Splits WORKAI_ROOT/CLAUDE.md (default ~/workai) at its `## ` headings, maps each
section to a hub by its number ("## 03 — ...") or old number ("(was L37)",
"## L36 — ..." through the hub README's old-number note), and prints the
mapping. Sections that map to no hub, or to several, are listed: decide those
by hand. With --write, each mapped section is saved as
<hub>/notes/workai-index-entry-<today>.md (an existing file is never
overwritten). Commits nothing.
"""
import re
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "workai-open-project"))
import report  # noqa: E402


def sections(text):
    out, head, body = [], None, []
    for line in text.splitlines():
        if line.startswith("## "):
            if head:
                out.append((head, "\n".join(body).strip()))
            head, body = line, []
        elif head:
            body.append(line)
    if head:
        out.append((head, "\n".join(body).strip()))
    return out


def main(args):
    write = "--write" in args
    rest = [a for a in args if a != "--write"]
    root = Path(rest[0]) if rest else Path.home() / "workai"
    hubs = report.all_hubs(root)
    by_num = {h.name[:2]: h for h, _ in hubs}
    by_old = {}
    for h, _ in hubs:
        for n in report.old_numbers(h):
            by_old.setdefault(n, []).append(h)
    unmapped, written = [], set()
    for head, body in sections(report.read(root / "CLAUDE.md")):
        m = re.match(r"## (\d{2}) ", head)
        targets = [by_num[m.group(1)]] if m and m.group(1) in by_num else []
        if not targets:
            olds = {int(n) for n in re.findall(r"\bL(\d+)\b", head)}
            targets = sorted({h for n in olds for h in by_old.get(n, [])})
        if len(targets) != 1:
            unmapped.append((head, [t.name for t in targets]))
            continue
        hub = targets[0]
        dest = hub / "notes" / f"workai-index-entry-{date.today()}.md"
        print(f"{head[3:60]:60} -> {dest.relative_to(root)} ({len(body)} chars)")
        if write and dest in written:  # a second section for the same hub (e.g. L36 into 01)
            with dest.open("a") as f:
                f.write(f"\n{head}\n{body}\n")
        elif write and not dest.exists():
            dest.parent.mkdir(exist_ok=True)
            dest.write_text(f"# Old workai index entry (saved {date.today()})\n\n{head}\n{body}\n")
            written.add(dest)
    for head, cands in unmapped:
        print(f"UNMAPPED {head[3:60]!r}: " + (", ".join(cands) if cands else "no hub"))
    if write:
        print(f"wrote {len(written)} file(s); nothing committed")
    # Sections without a project number (e.g. "## Instructions") are expected.
    return 1 if any(re.match(r"## (\d{2}|L\d+) ", h) for h, _ in unmapped) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
