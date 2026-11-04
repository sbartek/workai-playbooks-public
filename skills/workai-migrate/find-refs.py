#!/usr/bin/env python3
"""List everything that points at a path, so a move can update all of it.

Usage: find-refs.py PATH [PATH...]      paths relative to the workai root,
                                        e.g. projects/ceramics
Prints one line per reference: KIND  LOCATION  (line: TEXT). Exits 0 when
nothing points at any path, 1 when something does. Read-only.

Looks in: launchd plists, crontab, the workai CLAUDE.md and .gitignore,
memory notes, ~/.claude/MEMORY.md and ~/.claude/CLAUDE.md (read by every
session), Claude settings (hooks and permission rules: settings.json,
settings.local.json), shell rc files, skill symlinks, and text files in other
projects. A path followed by a full stop ("see projects/ceramics.") counts;
projects/ceramics.md does not.
Overrides for tests: WORKAI_ROOT, LAUNCHD_DIR, MEMORY_DIR, SKILLS_DIRS
(colon-separated), CRONTAB_FILE (read instead of `crontab -l`), CLAUDE_DIR
(instead of ~/.claude), RC_FILES (colon-separated, instead of the usual
~/.zshrc, ~/.bashrc, ...).
"""
import os
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
ROOT = Path(os.environ.get("WORKAI_ROOT", HOME / "workai"))
LAUNCHD = Path(os.environ.get("LAUNCHD_DIR", HOME / "Library/LaunchAgents"))
MEMORY = Path(os.environ.get("MEMORY_DIR", HOME / ".claude/projects/-Users-barteks/memory"))
SKILLS = [Path(p) for p in os.environ.get(
    "SKILLS_DIRS", f"{HOME}/.claude/skills:{HOME}/.agents/skills").split(":") if p]
CLAUDE_DIR = Path(os.environ.get("CLAUDE_DIR", HOME / ".claude"))
CLAUDE_FILES = ("MEMORY.md", "CLAUDE.md", "settings.json", "settings.local.json")
RC_FILES = [Path(p) for p in os.environ.get("RC_FILES", ":".join(
    str(HOME / f) for f in (".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"))).split(":") if p]
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", "worktrees", "results"}
SKIP_SUFFIXES = {".log", ".jsonl", ".sqlite", ".db", ".zip", ".png", ".jpg", ".jpeg", ".pdf", ".mp3", ".wav", ".parquet"}
MAX_BYTES = 1_000_000


def needles(rel):
    rel = rel.strip("/")
    absolute = str(ROOT / rel)
    tilde = "~/" + str((ROOT / rel).relative_to(HOME)) if str(ROOT).startswith(str(HOME)) else None
    return [n for n in {absolute, tilde, rel} if n]


def matches(text, rel):
    """Lines that mention the path as a whole path component."""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        for n in needles(rel):
            j = line.find(n)
            while j >= 0:
                end = j + len(n)
                # The path ends here: end of line, a separator, or a full stop
                # that ends a sentence (not projects/ceramics.md or ceramics.v2).
                nxt = line[end + 1] if end + 1 < len(line) else ""
                if (end == len(line) or not (line[end].isalnum() or line[end] in "-_.")
                        or (line[end] == "." and not (nxt.isalnum() or (nxt and nxt in "-_")))):
                    out.append((i, line.strip()))
                    break
                j = line.find(n, j + 1)
            else:
                continue
            break
    return out


def read(p):
    try:
        if p.stat().st_size > MAX_BYTES:
            return ""
        data = p.read_bytes()
    except OSError:
        return ""
    if b"\0" in data[:8192]:
        return ""  # binary
    return data.decode("utf-8", errors="ignore")


def crontab():
    f = os.environ.get("CRONTAB_FILE")
    if f is not None:
        return read(Path(f)) if f else ""
    r = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def scan(rels):
    """One pass over everything, checking all paths at once."""
    found = {rel: [] for rel in rels}

    def add(kind, where, text, show=True):
        for rel in rels:
            if not any(n in text for n in needles(rel)):
                continue
            for line_no, line in matches(text, rel):
                found[rel].append(f"{kind:9} {where}:{line_no}  "
                                  + (line[:160] if show else "(line not shown: settings may hold secrets)"))

    for plist in sorted(LAUNCHD.glob("*.plist")) if LAUNCHD.is_dir() else []:
        add("launchd", plist, read(plist))
    add("crontab", "crontab", crontab())
    for name in ("CLAUDE.md", ".gitignore"):
        add("workai", ROOT / name, read(ROOT / name))
    for note in sorted(MEMORY.glob("*.md")) if MEMORY.is_dir() else []:
        add("memory", note, read(note))
    for name in CLAUDE_FILES:
        # Permission rules have held credentials (adversarial review S2): never echo them.
        add("claude", CLAUDE_DIR / name, read(CLAUDE_DIR / name), show=not name.startswith("settings"))
    for rc in RC_FILES:
        add("shell rc", rc, read(rc))
    for d in SKILLS:
        for link in sorted(d.iterdir()) if d.is_dir() else []:
            if link.is_symlink():
                dest = os.readlink(link)
                for rel in rels:
                    target = str(ROOT / rel)
                    if dest == target or dest.startswith(target + "/"):
                        found[rel].append(f"{'symlink':9} {link} -> {dest}")
    targets = {rel: ROOT / rel for rel in rels}
    for area in ("projects", "archives"):
        base = ROOT / area
        for dirpath, dirnames, filenames in os.walk(base) if base.is_dir() else []:
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            here = Path(dirpath)
            inside = {rel for rel, t in targets.items() if here == t or t in here.parents}
            if len(inside) == len(rels):
                dirnames[:] = []
                continue
            for fn in filenames:
                if Path(fn).suffix.lower() in SKIP_SUFFIXES:
                    continue
                p = here / fn
                text = read(p)
                if not text or "projects/" not in text and "archives/" not in text:
                    continue
                for rel in rels:
                    if rel in inside or not any(n in text for n in needles(rel)):
                        continue
                    for line_no, line in matches(text, rel):
                        found[rel].append(f"{'file':9} {p}:{line_no}  {line[:160]}")
    return found


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    rels = [r.strip("/") for r in sys.argv[1:]]
    results = scan(rels)
    total = 0
    for rel in rels:
        found = results[rel]
        total += len(found)
        print(f"== {rel}: {len(found)} reference(s)")
        for f in found:
            print("   " + f)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
