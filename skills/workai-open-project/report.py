#!/usr/bin/env python3
"""Status report for one workai project hub: backlog and git state.

Usage: report.py PROJECT [WORKAI_ROOT]    e.g. report.py 1, report.py "my music"
PROJECT is a hub number (3, 03), an old number (L38, through the hub's
"old number L38" / "was L38" note) or a name or fragment of the hub's folder
name, README title, a folder name in its repos/ or a word in its README
`<!-- aliases: a, b -->` line ("my music", "impuestos 2026"; case and accents
ignored). An archived hub titled "(merged into NN ...)" gives way to hub NN
when both match.
Prints the hub path on the first line ("hub: <path>"), then the report.
Exits 2 if no hub matches, 3 (listing the candidates) if several do: it never
guesses.

       report.py --list [active|archived|all] [WORKAI_ROOT]
         one line per hub (default active = projects/ only): number, title,
         goal, cards in doing/ with WAITING/STALE flags, the number of parked
         cards, and git state when anything is uncommitted or unpushed.
       report.py --waiting [WORKAI_ROOT]
         "what's waiting on me", across every active hub: first todo/doing
         cards with `due:` within 14 days or past due (soonest first), then
         each card in doing/ with `waiting:` filled (hub, card, the question, the card
         file whose Notes say more), then STALE cards, then todo cards
         blocked only by waiting cards, then the parked cards (not now, never
         waiting on anyone; one line each).
       report.py --card CARD [WORKAI_ROOT]
         "status of card 042": one card's status (folder), claim, waiting,
         due, dependencies and the end of its Notes, in any hub, active or
         archived. CARD is `NN-NNN` (exact) or a bare id (`042`, `42`): a
         bare id inside a hub (the current directory) means that hub;
         elsewhere, matches in several hubs are listed (exit 3) and nothing
         is guessed. No match exits 2.
       report.py --index [WORKAI_ROOT]
         the compact workai index (~/workai/CLAUDE.md) as markdown: a fixed
         header, then one line per hub, active then archived, by number:
         number, title, old L number, goal, hub path, repos. The goal is the
         hub README's `<!-- index: ... -->` line when present, else the
         first sentence of its Goal with parentheses and identifiers
         (plates, NIE/DNI, phones, emails, IBANs) removed. State stays in
         the hub READMEs; never edit the generated file by hand.
       report.py --json NUMBER [WORKAI_ROOT]   one hub as JSON
       report.py --json --all [WORKAI_ROOT]    every hub in projects/ as JSON
         --archives  also hubs in archives/ (with --all)
         --git       also the git state of each hub, its repos and worktrees
                     ("git failed: <stderr>" when git could not run; those
                     places are listed in git.failed)
Git state is never "clean" when git failed: every mode prints "git failed:
<first stderr line>" instead.
JSON mode prints every card with its fields, body and computed flags
(claimable, blocked, parked, stale, waiting, overdue, activity_unknown, duplicate,
cycle, due_soon, past_due, waiting_old = waiting for more than 7 days since
`waiting_since:` or else `started:`; `overdue` = a done card overdue for archive/,
`past_due` = an open card past its `due:` date, `ungrouped` = an open card
without `youtrack:` in a hub where some card has one), due and due_in_days, youtrack, dependents, invalid_depends and dep_problems, plus "warnings" and "next":
the global Next list from WORKAI_ROOT/next.md (order, the todo cards it
shows, stale ids, warnings; one hub: only that hub's entries; an entry for a
parked card is stale). Each card's
"next" is its 1-based place among the shown Next cards, or null. Read-only.

Cards that cannot be read are skipped and listed under "warnings" (also printed
to stderr in every mode), as are duplicate ids (both cards kept), unreadable
priorities and depends entries that are not a card id of the hub.
A parked card (backlog/parked/, card 01-179) is wanted but deliberately not
now: never claimable, blocked, stale, due or ungrouped, and a card that
depends on it is blocked until it is unparked and finished. A doing card
whose branch git cannot read is activity_unknown, never stale.

next.md: one card label per line in order (`01-092`), optional ` # reason`;
blank lines and lines starting with `#` are ignored, a leading `-`, `*` or
`1.` is allowed. Capped at 5: more entries give a warning, nothing is dropped.

WORKAI_ROOT: in every mode the workai root is the positional WORKAI_ROOT
argument when given, else the WORKAI_ROOT environment variable when set and
non-empty, else ~/workai (like the shell scripts; tests point it at a fixture).
"""
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from datetime import date, datetime, timedelta
from pathlib import Path

STALE_SECONDS = 24 * 3600
WAITING_OLD_DAYS = 7  # a waiting card older than this is flagged waiting_old (asked, never answered)
DUE_SOON_DAYS = 14  # a todo/doing card with `due:` this close (or past) comes first
RECENT_DAYS = 7
AREAS = ("projects", "archives")
# "old number L38", "(was L38)", "(was `projects/ceramics`, L38)", Polish "stary
# numer L16", Spanish "número antiguo L16"; the note may wrap lines.
OLD_NUMBER_RE = re.compile(
    r"(?:old\s+number|stary\s+numer|n[uú]mero\s+antiguo|\(was(?:\s+`[^`]*`,)?)\s+L(\d+)\b", re.I)
GOAL_HEADINGS = ("goal", "cel", "objetivo", "objectiu")
NEXT_FILE = "next.md"
NEXT_CAP = 5
LABEL_RE = re.compile(r"^\d{2}-\d{3}$")


def default_root():
    """The workai root when no positional root is given: $WORKAI_ROOT, else ~/workai."""
    env = os.environ.get("WORKAI_ROOT", "")
    return Path(env) if env else Path.home() / "workai"


def find_hub(root, number):
    prefix = f"{number:02d}-"
    for area in AREAS:
        for p in sorted((root / area).glob(prefix + "*")):
            if p.is_dir():
                return p, area
    return None, None


def all_hubs(root, areas=AREAS):
    return [(p, a) for a in areas for p in sorted((root / a).glob("[0-9][0-9]-*")) if p.is_dir()]


def norm(text):
    """Lowercase, accents dropped, anything else non-alphanumeric to one space."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def read(path):
    try:
        return path.read_text()
    except (OSError, UnicodeDecodeError):
        return ""


def hub_title(hub):
    """README's first heading without the number ("My Music"), else the folder name."""
    for line in read(hub / "README.md").splitlines():
        if line.startswith("# "):
            return re.sub(r"^\d+\s*[—–-]+\s*", "", line[2:].strip())
    return hub.name.partition("-")[2]


def hub_goal(hub, width=110):
    """First sentence of the README's Goal section (or first plain paragraph)."""
    paragraphs, current, heading = [], [], None
    for line in read(hub / "README.md").splitlines() + [""]:
        if line.startswith("#"):
            if current:
                paragraphs.append((heading, " ".join(current)))
            current, heading = [], norm(line.lstrip("#"))
        elif line.strip() and not ALIASES_RE.match(line):
            current.append(line.strip())
        elif current:
            paragraphs.append((heading, " ".join(current)))
            current = []
    goal = next((t for h, t in paragraphs if h in GOAL_HEADINGS), None)
    if goal is None:
        goal = next((t for h, t in paragraphs
                     if not re.match(r"(project hub|hub projektu)\b", t, re.I)), "")
    return first_sentence(goal.replace("**", ""), width)


def first_sentence(text, width):
    """Up to the first full stop that ends a sentence, cut at width.

    A stop counts only outside parentheses, after a word of two or more
    letters and not before a digit, so "S.L.", "Reg. 883", "art. 62" and
    "(b. 2012)" do not end it.
    """
    depth = 0
    for i, c in enumerate(text[:width]):
        depth += (c == "(") - (c == ")")
        if c in ".!?" and depth <= 0 and (i + 1 == len(text) or text[i + 1] == " "):
            word = re.search(r"(\w+)[)\]]?$", text[:i])
            if word and len(word.group(1)) >= 2 and not text[i + 2:i + 3].isdigit():
                return text[: i + 1]
    return text if len(text) <= width else text[: width - 1].rstrip() + "…"


def old_numbers(hub):
    text = read(hub / "README.md") + "\n" + read(hub / "CLAUDE.md")
    return {int(n) for n in OLD_NUMBER_RE.findall(text)}


def resolve(root, query):
    """Hubs matching a number, an old L number, or a name fragment: [(path, area)].

    A name matches the hub's folder name, README title, the folder names in
    its repos/ and its README `<!-- aliases: ... -->` words. One element = a
    unique match. Several = ambiguous: the caller asks. Never picks among
    several, except that an archived hub merged into a matching hub (title
    "(merged into NN — ...)") is dropped, and a single hub with a whole name
    equal to the query wins over hubs that merely contain it.
    """
    q = query.strip()
    q = re.sub(r"^(?:work\s+on\s+|open\s+)?(?:the\s+)?project\s+(?=\S)", "", q, flags=re.I)
    m = re.fullmatch(r"\d{1,2}", q)
    if m:
        hub, area = find_hub(root, int(q))
        return [(hub, area)] if hub else []
    m = re.fullmatch(r"[Ll]\s*(\d{1,2})", q)
    if m:
        return [(h, a) for h, a in all_hubs(root) if int(m.group(1)) in old_numbers(h)]
    words = norm(q).split()
    if not words:
        return []
    phrase = " ".join(words)
    found, exact = [], []
    for h, a in all_hubs(root):
        names = hub_names(h)
        tokens = {t for n in names for t in n.split()}
        if all(any(t.startswith(w) for t in tokens) for w in words):
            found.append((h, a))
            if phrase in names:
                exact.append((h, a))
    # An archived hub merged into a hub that also matches gives way to it
    # (that hub may itself be archived later: a merge chain still resolves).
    numbers = {h.name.partition("-")[0] for h, a in found}
    found = [(h, a) for h, a in found if not (a == "archives" and merged_into(h) in numbers)]
    exact = [m for m in exact if m in found]
    return exact if len(exact) == 1 else found


ALIASES_RE = re.compile(r"^\s*<!--\s*aliases:\s*(.*?)\s*-->\s*$", re.M)
MERGED_INTO_RE = re.compile(r"\(merged into (\d{2})\b")


def hub_aliases(hub):
    """Words from the README's `<!-- aliases: a, b -->` line (lookup only)."""
    m = ALIASES_RE.search(read(hub / "README.md"))
    return [a.strip() for a in m.group(1).split(",") if a.strip()] if m else []


def hub_names(hub):
    """Every normalised name a hub answers to: its folder name, README title,
    the folder names in repos/ and its README aliases."""
    names = [hub.name.partition("-")[2], hub_title(hub)]
    names += sorted(p.name for p in (hub / "repos").glob("*") if p.is_dir())
    names += hub_aliases(hub)
    return {n for n in map(norm, names) if n}


def merged_into(hub):
    """'45' for an archived hub titled '... (merged into 45 — Household)', else None."""
    m = MERGED_INTO_RE.search(hub_title(hub))
    return m.group(1) if m else None


def hub_line(hub, area):
    number = hub.name.partition("-")[0]
    tag = " ARCHIVED" if area == "archives" else ""
    return f"{number}  {hub_title(hub)}  ({area}/{hub.name}){tag}"


def doing_flag(card):
    """The flag of a doing card, from the JSON flags (one source for every mode)."""
    if card["flags"]["waiting"]:
        old = f" (OLD: waiting {card['waiting_days']} days)" if card["flags"]["waiting_old"] else ""
        return f"WAITING{old}: {card['waiting']}"
    if card["flags"]["stale"]:
        return "STALE (no activity for 24h)"
    if card["flags"]["activity_unknown"]:
        return "activity unknown (git failed)"
    return ""


def git_summary(hub):
    """Only what needs attention: '' when the hub and every repo are clean and pushed."""
    states = [("hub", git_state(hub))]
    states += [(f"repos/{r.name}", git_state(r))
               for r in sorted(p for p in (hub / "repos").glob("*") if p.is_dir())]
    return "; ".join(f"{n} {s}" for n, s in states if s != "clean")


def list_main(args):
    rest = [a for a in args if a != "--list"]
    which = "active"
    if rest and rest[0] in ("active", "archived", "all"):
        which = rest.pop(0)
    if len(rest) > 1 or any(a.startswith("-") for a in rest):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(rest[0]) if rest else default_root()
    if not (root / "projects").is_dir():
        print(f"not a workai root (no projects/): {root}", file=sys.stderr)
        print(__doc__.strip(), file=sys.stderr)
        return 2
    areas = {"active": ("projects",), "archived": ("archives",), "all": AREAS}[which]
    now = time.time()
    for area in areas:
        hubs = all_hubs(root, (area,))
        print(f"{'active' if area == 'projects' else 'archived'} hubs in {root / area} ({len(hubs)}):")
        for hub, _ in hubs:
            print(hub_line(hub, area))
            goal = hub_goal(hub)
            if goal:
                print(f"    goal: {goal}")
            hub_cards_ = hub_json(hub, area, False, now)[1]
            for c in due_first(hub_cards_):
                print(f"    {due_text(c)}: {c['id']} {c['title']} [{c['status']}]")
            for c in hub_cards_:
                if c["status"] == "doing":
                    flag = doing_flag(c)
                    print(f"    doing: {c['id']} {c['title']} [{c['claimed_by'] or '?'}]"
                          + (f" {flag}" if flag else ""))
            parked = [c["id"] for c in hub_cards_ if c["status"] == "parked"]
            if parked:
                print(f"    parked ({len(parked)}): {', '.join(parked)}")
            g = git_summary(hub)
            if g:
                print(f"    git: {g}")
        if not hubs:
            print("  (none)")
        print()
    return 0


def notes_hint(body, width=160):
    """Last item of the card's Notes section (where the question usually is): a list
    item or paragraph with its wrapped lines joined, cut at width."""
    m = re.search(r"^## Notes\s*$(.*?)(?=^## |\Z)", body, re.M | re.S)
    items = []
    for line in (m.group(1) if m else "").splitlines():
        text = line.strip()
        if not text:
            items.append("")
        elif re.match(r"(?:[-*]|\d+[.)])\s", text) or not items or not items[-1]:
            items.append(text)
        else:
            items[-1] += " " + text
    items = [i for i in items if i]
    if not items:
        return ""
    last = re.sub(r"^(?:[-*])\s+", "", items[-1])
    return last if len(last) <= width else last[: width - 1].rstrip() + "…"


def waiting_main(args):
    rest = [a for a in args if a != "--waiting"]
    if len(rest) > 1 or any(a.startswith("-") for a in rest):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(rest[0]) if rest else default_root()
    if not (root / "projects").is_dir():
        print(f"not a workai root (no projects/): {root}", file=sys.stderr)
        return 2
    now = time.time()
    hubs, cards = {}, []
    for hub, area in all_hubs(root, ("projects",)):
        hubs[hub.name[:2]] = hub_title(hub)
        cards.extend(hub_json(hub, area, False, now)[1])
    by_label = {c["label"]: c for c in cards}
    due = due_first(cards)
    waiting = [c for c in cards if c["flags"]["waiting"]]
    stale = [c for c in cards if c["flags"]["stale"]]
    held = []  # todo cards whose every blocker is a waiting card
    for c in cards:
        if c["flags"]["blocked"]:
            blockers = [by_label.get(f"{c['project']}-{d}") for d in c["blocked_by"]]
            if all(b is not None and b["flags"]["waiting"] for b in blockers):
                held.append(c)

    def head(c):
        return f"  {c['label']}  {c['title']}  ({hubs[c['project']]})"

    print(f"due within {DUE_SOON_DAYS} days or past due ({len(due)}):")
    for c in due:
        print(head(c) + f"  {due_text(c)}  [{c['status']}]")
        print(f"      card: {c['path']}")
    if not due:
        print("  (none)")
    print(f"\nwaiting on you ({len(waiting)}):")
    for c in waiting:
        age = c["waiting_days"]
        since = ("" if age is None else f"  waiting {age} days, OLD: ask again or release" if c["flags"]["waiting_old"]
                 else "" if age <= 0 else f"  waiting {age} day{'s' if age != 1 else ''}")
        print(head(c) + since)
        print(f"      question: {c['waiting']}")
        hint = notes_hint(c["body"])
        if hint:
            print(f"      notes: {hint}")
        print(f"      card: {c['path']}")
    if not waiting:
        print("  (none)")
    print(f"\nstale, no activity for 24h ({len(stale)}):")
    for c in stale:
        print(head(c) + f"  [{c['claimed_by'] or '?'}]")
    if not stale:
        print("  (none)")
    print(f"\nblocked only by waiting cards ({len(held)}):")
    for c in held:
        print(head(c) + "  blocked by " + ", ".join(f"{c['project']}-{d}" for d in c["blocked_by"]))
    if not held:
        print("  (none)")
    parked = [c for c in cards if c["flags"]["parked"]]
    print(f"\nparked, not now ({len(parked)}):")
    for c in parked:
        print(head(c))
    if not parked:
        print("  (none)")
    return 0


WARNINGS = []  # problems found while reading cards; printed to stderr, in JSON under "warnings"


def warn(message):
    if message not in WARNINGS:
        WARNINGS.append(message)


def print_warnings():
    for w in WARNINGS:
        print(f"warning: {w}", file=sys.stderr)


def strip_comment(value):
    """A frontmatter value without its trailing ` # comment` (YAML: a `#` after
    whitespace), keeping a `#` inside a quoted string."""
    v = value.strip()
    if v.startswith('"'):
        m = re.match(r'"(?:[^"\\]|\\.)*"', v)
        if m:
            return m.group(0)
    if v.startswith("'"):
        m = re.match(r"'(?:[^']|'')*'", v)
        if m:
            return m.group(0)
    if v.startswith("#"):
        return ""
    return re.split(r"\s#", v, maxsplit=1)[0].strip()


def parse_card(text):
    """Return (fields, body) of a card's text.

    Values lose a trailing ` # comment` and their quotes (`\\"` and `''` inside
    them become `"` and `'`). A key with no
    value followed by `  - item` lines (a block-style YAML list) becomes
    "[item, item]", the same as the flow form.
    """
    m = re.match(r"---\r?\n(.*?)\r?\n---\r?\n?", text, re.S)
    fields, last = {}, None
    for line in (m.group(1) if m else "").splitlines():
        item = re.match(r"\s*-\s+(.*)$", line)
        if item and last is not None and (fields[last] == "" or fields[last].startswith("[")):
            entry = strip_comment(item.group(1))
            old = fields[last][1:-1] if fields[last].startswith("[") else ""
            fields[last] = "[" + ", ".join(x for x in (old, entry) if x) + "]"
            continue
        key, sep, value = line.partition(":")
        if sep and key.strip() and not key.startswith((" ", "\t")):
            value = strip_comment(value)
            if len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1].replace('\\"', '"')
            elif len(value) >= 2 and value[0] == value[-1] == "'":
                value = value[1:-1].replace("''", "'")
            last = key.strip()
            fields[last] = value
        else:
            last = None
    return fields, text[m.end():] if m else text


def parse_depends(value):
    """`depends:` as (ids, invalid): ids zero-padded to three digits; anything
    that is not a bare card id of this hub (`02-001`, `abc`) is invalid."""
    v = (value or "").strip()
    if v.startswith("[") and v.endswith("]"):
        v = v[1:-1]
    good, bad = [], []
    for part in re.split(r"[,\s]+", v):
        part = part.strip().strip("'\"")
        if not part:
            continue
        if re.fullmatch(r"\d{1,3}", part):
            if part.zfill(3) not in good:
                good.append(part.zfill(3))
        else:
            bad.append(part)
    return good, bad


PRIORITY_WORDS = {"high": 1, "normal": 2, "medium": 2, "low": 3}


def prio(value):
    """`priority:` as an int (1 high, 2 normal, 3 low; the words work too), or
    None when empty or unreadable. The one parser every mode uses."""
    v = (value or "").strip().lower()
    if re.fullmatch(r"\d+", v):
        return int(v)
    return PRIORITY_WORDS.get(v)


def ids(value):
    return parse_depends(value)[0]


def run_git(*args, cwd):
    """(ok, stdout, first stderr line). Never raises: a missing git is a failure too."""
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    except OSError as e:
        return False, "", str(e)
    err = next((l.strip() for l in r.stderr.splitlines() if l.strip()), "")
    if r.returncode != 0 and not err:
        err = f"exit {r.returncode}"
    return r.returncode == 0, r.stdout.strip(), err


def mtime(path):
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def playbooks_version():
    """Version of the skills this report.py belongs to, e.g. '1.1.0 (release v1.1.0)'
    or '1.0.0 (live checkout, 24 commits after v1.0.0)'."""
    root = Path(__file__).resolve().parent.parent.parent
    try:
        version = (root / "VERSION").read_text().strip()
    except OSError:
        return "unknown (no VERSION file)"
    ok, d, _ = run_git("describe", "--tags", "--match", "v[0-9]*", cwd=root)
    if not ok or not d:
        return f"{version} (not a git checkout)"
    m = re.fullmatch(r"(v[0-9.]+)-([0-9]+)-g[0-9a-f]+", d)
    if m:
        return f"{version} (live checkout, {m.group(2)} commits after {m.group(1)})"
    return f"{version} (release {d})"


def last_activity(hub, card_path, f):
    """Newest activity time of a doing card, or None when it cannot be known
    (git failed on the card's branch, or the card file vanished): an unknown
    activity is never STALE."""
    t = mtime(card_path)
    if t is None:
        return None
    times = [t]
    repo, branch, wt = f.get("repo", ""), f.get("branch", ""), f.get("worktree", "")
    repo_dir = hub / "repos" / repo
    if repo and repo != "hub" and branch.startswith("card/") and repo_dir.is_dir():
        ok, out, _ = run_git("log", "-1", "--format=%ct", branch, cwd=repo_dir)
        if ok and out.isdigit():
            times.append(int(out))
        elif not run_git("rev-parse", "--git-dir", cwd=repo_dir)[0]:
            return None  # git itself failed: the branch may be busy right now
        # else git works and the branch is gone: only the card and worktree count
    if wt.startswith("worktrees/") and (hub / wt).is_dir():
        for p in (hub / wt).rglob("*"):
            if ".git" not in p.parts and p.is_file():
                t = mtime(p)
                if t is not None:
                    times.append(t)
    return max(times)


# rev-list @{u} fails on purpose when a branch has no upstream (or HEAD is
# detached); any other failure is git failing, never "no upstream".
NO_UPSTREAM_RE = re.compile(r"no upstream|does not point to a branch|no such branch", re.I)
GIT_FAILED = "git failed: "


def git_state(path):
    """'clean', 'N uncommitted', ', no upstream', ', N unpushed' - or
    'git failed: <first stderr line>' when git could not tell. Never claims
    clean (or no upstream) on a git failure."""
    if not (path / ".git").exists():
        return "not a git repo"
    ok, out, err = run_git("status", "--porcelain", cwd=path)
    if not ok:
        return GIT_FAILED + err
    dirty = len([l for l in out.splitlines() if l])
    parts = [f"{dirty} uncommitted" if dirty else "clean"]
    ok, ahead, err = run_git("rev-list", "--count", "@{u}..HEAD", cwd=path)
    if not ok:
        parts.append("no upstream" if NO_UPSTREAM_RE.search(err) else GIT_FAILED + err)
    elif ahead != "0":
        parts.append(f"{ahead} unpushed")
    return ", ".join(parts)


# parked/ (card 01-179): wanted, deliberately not now; optional folder, created
# by the first card parked in a hub.
STATUSES = ("todo", "doing", "parked", "done", "archive")


def read_card(p):
    """(fields, body) of one card file, or None when it cannot be read (dangling
    symlink, moved away mid-scan, a directory): skipped with a warning. Bytes
    that are not UTF-8 are replaced, with a warning, and the card is kept."""
    try:
        raw = p.read_bytes()
    except OSError as e:
        warn(f"skipped unreadable card {p}: {e.strerror or e}")
        return None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")
        warn(f"card {p} is not valid UTF-8; bad bytes shown as �")
    return parse_card(text)


def hub_cards(hub):
    """Every readable card of a hub as [(id, status, path, fields, body)], in
    folder order. Two files with the same id are both kept (and warned about):
    one must never hide the other."""
    cards = []
    for status in STATUSES:
        for p in sorted((hub / "backlog" / status).glob("[0-9][0-9][0-9]-*.md")):
            parsed = read_card(p)
            if parsed is not None:
                cards.append((p.name[:3], status, p, *parsed))
    seen = {}
    for i, status, p, _, _ in cards:
        seen.setdefault(i, []).append(f"{status}/{p.name}")
    for i, where in seen.items():
        if len(where) > 1:
            warn(f"duplicate card id {hub.name[:2]}-{i} in {hub / 'backlog'}: {', '.join(where)}")
    return cards


def cycle_through(start, deps):
    """A dependency path from start back to start ([start, ..., start]), or None."""
    stack, seen = [(start, [start])], set()
    while stack:
        node, path = stack.pop()
        for d in deps.get(node, ()):
            if d == start:
                return path + [start]
            if d not in seen:
                seen.add(d)
                stack.append((d, path + [d]))
    return None


def finished_date(f):
    try:
        return datetime.strptime(f.get("finished", "")[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


def waiting_age(f, today=None):
    """Days a doing card has been waiting: since `waiting_since:` when set, else
    since `started:` (the claim; never later than the wait). None when neither
    is a date: unknown is never flagged."""
    for key in ("waiting_since", "started"):
        try:
            d = datetime.strptime((f.get(key) or "").strip()[:10], "%Y-%m-%d").date()
        except ValueError:
            continue
        return ((today or date.today()) - d).days
    return None


def due_date(value):
    """`due: YYYY-MM-DD` as a date, or None (empty or unreadable)."""
    try:
        return datetime.strptime((value or "").strip(), "%Y-%m-%d").date()
    except ValueError:
        return None


def due_text(card):
    """"due 2026-10-27 (in 3 days)", "due 2026-10-24 (TODAY)", "PAST DUE 2026-10-20 (4 days ago)"."""
    days = card["due_in_days"]
    if days is None:
        return ""
    if days < 0:
        return f"PAST DUE {card['due']} ({-days} day{'s' if days != -1 else ''} ago)"
    when = "TODAY" if days == 0 else "tomorrow" if days == 1 else f"in {days} days"
    return f"due {card['due']} ({when})"


def due_first(cards):
    """Cards due within DUE_SOON_DAYS or past due, soonest first."""
    return sorted((c for c in cards if c["flags"]["due_soon"] or c["flags"]["past_due"]),
                  key=lambda c: (c["due"], c["label"]))


def hub_json(hub, area, with_git, now):
    number, _, name = hub.name.partition("-")
    structure = read(hub / "STRUCTURE").strip() or None
    info = {"number": number, "name": name, "path": str(hub), "area": area, "structure": structure}
    if with_git:
        repos = {r.name: git_state(r) for r in sorted(p for p in (hub / "repos").glob("*") if p.is_dir())}
        info["git"] = {
            "hub": git_state(hub),
            "repos": repos,
            "worktrees": [str(p.relative_to(hub)) for p in sorted((hub / "worktrees").glob("*/*")) if p.is_dir()],
        }
        # Added by card 100: where git itself failed ("hub" or "repos/<name>"), so a
        # consumer can tell "could not check" from "clean" without parsing strings.
        info["git"]["failed"] = [n for n, s in [("hub", info["git"]["hub"])]
                                 + [(f"repos/{r}", s) for r, s in repos.items()] if GIT_FAILED in s]
    cards = hub_cards(hub)
    by_id = {}
    for i, status, _, _, _ in cards:
        by_id.setdefault(i, []).append(status)
    # An id counts as finished only when every card carrying it is finished.
    finished = {i for i, ss in by_id.items() if all(s in ("done", "archive") for s in ss)}
    parsed = {p: parse_depends(f.get("depends")) for _, _, p, f, _ in cards}
    graph = {}
    for i, _, p, _, _ in cards:
        graph.setdefault(i, [])
        graph[i] += [d for d in parsed[p][0] if d not in graph[i]]
    dependents = {i: [] for i in by_id}
    for i, _, p, _, _ in cards:
        for d in parsed[p][0]:
            if i not in dependents.setdefault(d, []):
                dependents[d].append(i)
    # Card 147: a hub is grouped once any of its cards has `youtrack:`; from
    # then on every open card must carry one.
    grouped = any(f.get("youtrack", "").strip() for _, _, _, f, _ in cards)
    out = []
    for i, status, p, f, body in cards:
        depends, invalid = parsed[p]
        priority = prio(f.get("priority"))
        if priority is None and f.get("priority", "").strip():
            warn(f"card {number}-{i} ({p}): priority {f['priority']!r} is not 1-3 or high/normal/low")
        problems = []
        if invalid:
            problems.append("not a card id of this hub: " + ", ".join(invalid))
            warn(f"card {number}-{i} ({p}): depends {', '.join(invalid)} is not a card id of this hub"
                 " (cross-hub dependencies are not supported)")
        cycle = cycle_through(i, graph)
        if cycle:
            problems.append("depends on itself" if len(cycle) == 2 else "dependency cycle: " + " -> ".join(cycle))
        waiting = f.get("waiting", "")
        activity = last_activity(hub, p, f) if status == "doing" else None
        fin = finished_date(f)
        due = due_date(f.get("due"))
        if due is None and f.get("due", "").strip():
            warn(f"card {number}-{i} ({p}): due {f['due']!r} is not a date (YYYY-MM-DD)")
        due_in = (due - date.today()).days if due else None
        open_card = status in ("todo", "doing")
        is_waiting = status == "doing" and bool(waiting)
        wait_days = waiting_age(f) if is_waiting else None
        # Invalid entries block too: a card is claimable only when every
        # dependency is a finished card of this hub.
        blocked_by = [d for d in depends if d not in finished] + invalid
        out.append({
            "project": number,
            "project_name": name,
            "label": f"{number}-{i}",
            "id": i,
            "title": f.get("title", ""),
            "status": status,
            "priority": priority,
            "repo": f.get("repo", ""),
            "depends": depends,
            "dependents": sorted(dependents.get(i, [])),
            "blocked_by": blocked_by,
            "missing": [d for d in depends if d not in by_id],
            "invalid_depends": invalid,
            "dep_problems": problems,
            "claimed_by": f.get("claimed_by", ""),
            "worktree": f.get("worktree", ""),
            "branch": f.get("branch", ""),
            "started": f.get("started", ""),
            "waiting": waiting,
            "waiting_since": f.get("waiting_since", ""),
            "waiting_days": wait_days,
            "finished": f.get("finished", ""),
            "due": due.isoformat() if due else "",
            "due_in_days": due_in,
            "youtrack": f.get("youtrack", "").strip(),
            "flags": {
                "claimable": status == "todo" and not blocked_by,
                "blocked": status == "todo" and bool(blocked_by),
                "parked": status == "parked",
                "waiting": is_waiting,
                "waiting_old": wait_days is not None and wait_days > WAITING_OLD_DAYS,
                "stale": status == "doing" and not waiting and activity is not None
                         and now - activity > STALE_SECONDS,
                "activity_unknown": status == "doing" and activity is None,
                "overdue": status == "done" and fin is not None and (date.today() - fin).days > 14,
                "duplicate": len(by_id[i]) > 1,
                "due_soon": open_card and due_in is not None and 0 <= due_in <= DUE_SOON_DAYS,
                "past_due": open_card and due_in is not None and due_in < 0,
                "cycle": cycle is not None,
                "ungrouped": open_card and grouped and not f.get("youtrack", "").strip(),
            },
            "last_activity": activity,
            "mtime": mtime(p),
            "path": str(p),
            "body": body,
        })
    return info, out


def read_next(root):
    """Parse WORKAI_ROOT/next.md: [{"label", "reason"}] in order, plus invalid lines and duplicates."""
    path = root / NEXT_FILE
    entries, invalid, duplicates, seen = [], [], [], set()
    for n, raw in enumerate(read(path).splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = re.sub(r"^(?:[-*]|\d+[.)])\s+", "", line)
        label, _, reason = line.partition("#")
        label = label.strip()
        if not LABEL_RE.match(label):
            invalid.append(f"line {n}: {raw.strip()}")
        elif label in seen:
            duplicates.append(label)
        else:
            seen.add(label)
            entries.append({"label": label, "reason": reason.strip()})
    return {"path": str(path), "exists": path.is_file(), "entries": entries,
            "invalid": invalid, "duplicates": duplicates}


def next_view(root, cards, numbers=None):
    """The Next list against the cards: shown (in todo/, in order) and stale (anything else).

    `cards` are the JSON card dicts; each gets "next" = place among the shown
    cards or None. `numbers` limits the view to those hubs (one-hub mode).
    """
    parsed = read_next(root)
    by_label = {c["label"]: c for c in cards}
    for c in cards:
        c["next"] = None
    order = [e for e in parsed["entries"] if numbers is None or e["label"][:2] in numbers]
    shown, stale = [], []
    for e in order:
        card = by_label.get(e["label"])
        if card is not None and card["status"] == "todo":
            shown.append(e["label"])
            card["next"] = len(shown)
        else:
            if card is not None:
                status = card["status"]
            else:
                hub, area = find_hub(root, int(e["label"][:2]))
                status = "archived hub" if area == "archives" else "missing"
            stale.append({"label": e["label"], "status": status, "reason": e["reason"]})
    warnings = []
    if len(order) > NEXT_CAP:
        warnings.append(f"next.md has {len(order)} entries; the cap is {NEXT_CAP}")
    if stale:
        warnings.append("next.md: stale " + ", ".join(f"{x['label']} ({x['status']})" for x in stale))
    if parsed["invalid"]:
        warnings.append("next.md: not a card label: " + "; ".join(parsed["invalid"]))
    if parsed["duplicates"]:
        warnings.append("next.md: listed twice: " + ", ".join(parsed["duplicates"]))
    return {"path": parsed["path"], "exists": parsed["exists"], "cap": NEXT_CAP, "order": order,
            "shown": shown, "stale": stale, "invalid": parsed["invalid"],
            "duplicates": parsed["duplicates"], "over_cap": len(order) > NEXT_CAP, "warnings": warnings}


def notes_tail(body, n=3, width=300):
    """The last n items of a card's Notes section, each cut at width."""
    m = re.search(r"^## Notes\s*$(.*?)(?=^## |\Z)", body, re.M | re.S)
    items = []
    for line in (m.group(1) if m else "").splitlines():
        text = line.strip()
        if not text:
            items.append("")
        elif re.match(r"(?:[-*]|\d+[.)])\s", text) or not items or not items[-1]:
            items.append(text)
        else:
            items[-1] += " " + text
    items = [re.sub(r"^[-*]\s+", "", i) for i in items if i]
    return [i if len(i) <= width else i[: width - 1].rstrip() + "…" for i in items[-n:]]


def hub_of_cwd(root, cwd=None):
    """The hub (path, area) the current directory is in, or (None, None)."""
    try:
        here = (cwd or Path.cwd()).resolve()
    except OSError:
        return None, None
    for hub, area in all_hubs(root):
        try:
            here.relative_to(hub.resolve())
            return hub, area
        except ValueError:
            continue
    return None, None


def card_status_line(c):
    f = c["flags"]
    if c["status"] == "doing":
        who = f"claimed by {c['claimed_by'] or '?'}" + (f" since {c['started']}" if c["started"] else "")
        if f["waiting"]:
            old = f", OLD: waiting {c['waiting_days']} days" if f.get("waiting_old") else ""
            return f"doing, WAITING ({who}{old}): {c['waiting']}"
        if f["stale"]:
            return f"doing, STALE: no activity for 24h ({who})"
        return f"doing ({who})"
    if c["status"] == "todo":
        if f["blocked"]:
            return "todo, blocked by " + ", ".join(f"{c['project']}-{d}" for d in c["blocked_by"])
        return "todo, claimable" + (f" (Next #{c['next']})" if c.get("next") else "")
    if c["status"] == "parked":
        return "parked: not now, never claimable (unpark by moving it to todo/)"
    return f"{c['status']}, finished {c['finished'] or '?'}"


def card_main(args):
    rest = [a for a in args if a != "--card"]
    if not rest or len(rest) > 2 or any(a.startswith("-") for a in rest):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(rest[1]) if len(rest) > 1 else default_root()
    if not (root / "projects").is_dir():
        print(f"not a workai root (no projects/): {root}", file=sys.stderr)
        return 2
    q = re.sub(r"^(?:status\s+of\s+)?(?:the\s+)?card\s+", "", rest[0].strip(), flags=re.I)
    m = re.fullmatch(r"(?:(\d{1,2})-)?(\d{1,3})", q)
    if not m:
        print(f"not a card id: {rest[0]!r} (use NN-NNN or NNN)")
        return 2
    cid = m.group(2).zfill(3)
    if m.group(1):
        hub, area = find_hub(root, int(m.group(1)))
        hubs = [(hub, area)] if hub else []
        scope = f"hub {int(m.group(1)):02d}"
    else:
        hubs = all_hubs(root)
        scope = "any hub"
    now = time.time()
    found = []
    for hub, area in hubs:
        info, cards = hub_json(hub, area, False, now)
        next_view(root, cards)
        found += [(hub, area, c) for c in cards if c["id"] == cid]
    here, _ = hub_of_cwd(root)
    if not m.group(1) and here is not None:
        mine = [x for x in found if x[0] == here]
        if mine:
            found = mine
        elif found:
            print(f"note: no card {cid} in the current hub ({here.name}); found elsewhere:")
    if not found:
        print(f"no card {cid} in {scope} under {root}/projects or {root}/archives")
        return 2
    if len(found) > 1 and len({x[0] for x in found}) > 1:
        print(f"card {cid} is in several hubs; ask which one:")
        for hub, area, c in found:
            print(f"  {c['label']}  {c['title']}  ({hub_title(hub)}, {area}/{hub.name})  [{c['status']}]")
        return 3
    for hub, area, c in found:  # one card, or duplicates of one id inside one hub
        print(f"card: {c['label']}  {c['title']}")
        print(f"project: {hub_title(hub)} ({area}/{hub.name})" + ("  ARCHIVED" if area == "archives" else ""))
        print(f"status: {card_status_line(c)}")
        if c["flags"].get("duplicate"):
            print("warning: another card in this hub has the same id")
        if c["due"]:
            print(f"due: {due_text(c)}")
        if c["youtrack"]:
            print(f"group: {c['youtrack']} (YouTrack)")
        if c["status"] == "doing" and c["repo"] != "hub":
            print(f"worktree: {c['worktree'] or '-'}  branch: {c['branch'] or '-'}")
        if c["depends"] or c["invalid_depends"]:
            print(f"depends: {', '.join(c['depends'] + c['invalid_depends'])}")
        if c["dependents"]:
            print(f"needed by: {', '.join(c['dependents'])}")
        print(f"file: {c['path']}")
        tail = notes_tail(c["body"])
        print("notes (last items):" if tail else "notes: (empty)")
        for item in tail:
            print(f"  - {item}")
    return 0


INDEX_OVERRIDE_RE = re.compile(r"<!--\s*index:\s*(.*?)\s*-->", re.S)
# Identifiers that must never reach the always-loaded index (adversarial review S11).
SCRUB_RES = [
    re.compile(r"\([^()]*\)"),                                   # parenthesised details
    re.compile(r"\b[A-Z]{2}\d{2}(?:\s?[0-9A-Z]{4}){3,}\b"),       # IBAN
    re.compile(r"\b[XYZ]?\d{7,8}[A-Z]\b"),                       # NIE / DNI
    re.compile(r"\b\d{4}\s?[BCDFGHJKLMNPRSTVWXYZ]{3}\b"),           # Spanish plate
    re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"),                       # email
    re.compile(r"\+?\d[\d .-]{7,}\d"),                            # phone-like number runs
]
INDEX_GOAL_WIDTH = 100
INDEX_HEADER = """# Workai index

Generated by `report.py --index` (workai-open-project skill): do not edit by
hand, regenerate. One line per project hub; each hub's README holds its goal,
plan and state, its CLAUDE.md the rules for working in it.

- `~/workai` has two folders: `projects/` (active hubs) and `archives/`
  (inactive). A hub is `NN-name/`, its own private git repo, with `backlog/`,
  `notes/`, `repos/` (outcome repos) and `worktrees/`.
- "project N" or a bare number means hub NN. Old numbers carry an `L`
  (`L38`); the hub's README records it. To open a project use the
  workai-open-project skill; to list them, workai-list-projects; for the
  layout, workai-structure.
- Before working in a hub, read its README.md and CLAUDE.md.
"""


def index_goal(hub):
    m = INDEX_OVERRIDE_RE.search(read(hub / "README.md"))
    if m:
        return " ".join(m.group(1).split())
    goal = hub_goal(hub, width=400)
    for r in SCRUB_RES:
        goal = r.sub("", goal)
    goal = re.sub(r"\([^()]*$", "", goal)  # a parenthesis the sentence cut left open
    goal = re.sub(r"\s+([,.;:])", r"\1", re.sub(r"\s{2,}", " ", goal)).strip(" ,;:")
    return goal if len(goal) <= INDEX_GOAL_WIDTH else goal[: INDEX_GOAL_WIDTH - 1].rstrip() + "…"


def index_line(hub, area):
    number = hub.name.partition("-")[0]
    old = ", ".join(f"L{n}" for n in sorted(old_numbers(hub)))
    repos = sorted(p.name for p in (hub / "repos").glob("*") if p.is_dir())
    parts = [f"- **{number} {hub_title(hub)}**" + (f" (was {old})" if old else "")]
    goal = index_goal(hub)
    line = parts[0] + (f": {goal}" if goal else "")
    line += f" `{area}/{hub.name}/`"
    if repos:
        line += " repos: " + ", ".join(repos)
    return line


def index_main(args):
    rest = [a for a in args if a != "--index"]
    if len(rest) > 1 or any(a.startswith("-") for a in rest):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(rest[0]) if rest else default_root()
    if not (root / "projects").is_dir():
        print(f"not a workai root (no projects/): {root}", file=sys.stderr)
        return 2
    print(INDEX_HEADER)
    for area, heading in (("projects", "Active"), ("archives", "Archived")):
        hubs = sorted(all_hubs(root, (area,)), key=lambda x: x[0].name)
        print(f"## {heading} ({len(hubs)})\n")
        for hub, _ in hubs:
            print(index_line(hub, area))
        print()
    return 0


def json_main(args):
    flags = {a for a in args if a.startswith("--")}
    rest = [a for a in args if not a.startswith("--")]
    unknown = flags - {"--json", "--all", "--archives", "--git"}
    want_all = "--all" in flags
    if unknown or (want_all and len(rest) > 1) or (not want_all and (not rest or not rest[0].isdigit() or len(rest) > 2)):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root_arg = rest[0] if want_all and rest else (rest[1] if len(rest) > 1 else None)
    root = Path(root_arg) if root_arg else default_root()
    if want_all:
        areas = ("projects", "archives") if "--archives" in flags else ("projects",)
        hubs = [(p, a) for a in areas for p in sorted((root / a).glob("[0-9][0-9]-*")) if p.is_dir()]
    else:
        hub, area = find_hub(root, int(rest[0]))
        if not hub:
            print(f"no hub numbered {int(rest[0]):02d} in {root}/projects or {root}/archives", file=sys.stderr)
            return 2
        hubs = [(hub, area)]
    now = time.time()
    result = {"root": str(root), "generated": datetime.now().isoformat(timespec="seconds"), "hubs": [], "cards": []}
    for hub, area in hubs:
        info, cards = hub_json(hub, area, "--git" in flags, now)
        result["hubs"].append(info)
        result["cards"].extend(cards)
    result["next"] = next_view(root, result["cards"], None if want_all else {h.name[:2] for h, _ in hubs})
    result["warnings"] = list(WARNINGS)
    json.dump(result, sys.stdout, indent=1)
    print()
    return 0


def main():
    args = sys.argv[1:]
    if "--json" in args:
        return json_main(args)
    if "--list" in args:
        return list_main(args)
    if "--waiting" in args:
        return waiting_main(args)
    if "--card" in args:
        return card_main(args)
    if "--index" in args:
        return index_main(args)
    if not args or any(a.startswith("-") for a in args):
        print(__doc__.strip())
        return 2
    # The last argument is the workai root when it is one (has projects/);
    # everything before it is the query, so an unquoted name still works.
    root = default_root()
    if len(args) > 1 and (Path(args[-1]) / "projects").is_dir():
        root = Path(args.pop())
    query = " ".join(args)
    matches = resolve(root, query)
    if not matches:
        if query.strip().isdigit():
            print(f"no hub numbered {int(query):02d} in {root}/projects or {root}/archives")
        else:
            print(f"no hub matches {query!r} in {root}/projects or {root}/archives")
        return 2
    if len(matches) > 1:
        print(f"several hubs match {query!r}; ask which one:")
        for h, a in matches:
            print(f"  {hub_line(h, a)}")
        return 3
    hub, area = matches[0]
    print(f"hub: {hub}")
    if area == "archives":
        print("note: this project is ARCHIVED")
    structure = read(hub / "STRUCTURE").strip() or "none recorded"
    print(f"structure: {structure}")
    print(f"playbooks: {playbooks_version()}")

    # Everything below comes from the same card dicts and flags as --json.
    now = time.time()
    cards = hub_json(hub, area, False, now)[1]
    due = due_first(cards)
    if due:
        print(f"\ndue within {DUE_SOON_DAYS} days or past due:")
        for c in due:
            print(f"  {c['id']} {c['title']} [{c['status']}] {due_text(c)}")
    print("\ndoing:")
    doing = [c for c in cards if c["status"] == "doing"]
    for c in doing:
        flag = doing_flag(c)
        print(f"  {c['id']} {c['title']} [{c['claimed_by'] or '?'}; worktree {c['worktree'] or '-'}]"
              + (" " + flag if flag else ""))
    if not doing:
        print("  (none)")

    todo = [c for c in cards if c["status"] == "todo"]
    ready = [c for c in todo if c["flags"]["claimable"]]
    blocked = len(todo) - len(ready)
    # Picking order: Next (WORKAI_ROOT/next.md) first, in its order, then priority, then id.
    number = hub.name[:2]
    nxt = read_next(root)["entries"]
    hub_next = [e["label"][3:] for e in nxt if e["label"][:2] == number]
    place = {i: k for k, i in enumerate(hub_next)}
    ready.sort(key=lambda c: (place.get(c["id"], len(place)), c["priority"] or 9, c["id"]))
    print(f"\nclaimable ({len(ready)}), in picking order (Next first):")
    for c in ready:
        tag = " [next]" if c["id"] in place else ""
        print(f"  {c['id']} p{c['priority'] or '?'} {c['title']}{tag}")
    if not ready:
        print("  (none)")
    print(f"blocked: {blocked} card(s) waiting on dependencies")
    problems = [c for c in cards if c["dep_problems"]]
    for c in problems:
        print(f"  {c['id']} depends: {'; '.join(c['dep_problems'])}")
    ungrouped = [c for c in cards if c["flags"]["ungrouped"]]
    if ungrouped:
        print(f"without a group (no youtrack:): {', '.join(c['id'] for c in ungrouped)}")
    in_todo = {c["id"] for c in todo}
    ready_ids = {c["id"] for c in ready}
    blocked_next = [i for i in hub_next if i in in_todo and i not in ready_ids]
    if blocked_next:
        print(f"in Next but blocked (unblock them): {', '.join(blocked_next)}")
    stale_next = [i for i in hub_next if i not in in_todo]
    if stale_next:
        print(f"stale in {root / NEXT_FILE} (not in todo/, prune): {', '.join(number + '-' + i for i in stale_next)}")
    if len(nxt) > NEXT_CAP:
        print(f"warning: {root / NEXT_FILE} has {len(nxt)} entries; the cap is {NEXT_CAP}")
    dups = sorted({c["id"] for c in cards if c["flags"]["duplicate"]})
    if dups:
        print(f"duplicate card ids (renumber one of each): {', '.join(dups)}")

    parked = [c for c in cards if c["status"] == "parked"]
    print(f"\nparked ({len(parked)}), not now, never claimable:")
    for c in parked:
        print(f"  {c['id']} p{c['priority'] or '?'} {c['title']}")
    if not parked:
        print("  (none)")

    cutoff = date.today() - timedelta(days=RECENT_DAYS)
    recent = []
    for c in cards:
        d = finished_date(c)
        if c["status"] == "done" and d is not None and d >= cutoff:
            recent.append((d, c["id"], c["title"]))
    overdue = [c["id"] for c in cards if c["flags"]["overdue"]]
    print(f"\nfinished in the last {RECENT_DAYS} days ({len(recent)}):")
    for d, i, t in sorted(recent, reverse=True):
        print(f"  {i} {t} ({d})")
    if overdue:
        print(f"done cards overdue for archive/: {', '.join(sorted(overdue))}")

    print("\ngit:")
    print(f"  hub: {git_state(hub)}")
    for repo in sorted(p for p in (hub / "repos").glob("*") if p.is_dir()):
        print(f"  repos/{repo.name}: {git_state(repo)}")
    wts = sorted(p.relative_to(hub) for p in (hub / "worktrees").glob("*/*") if p.is_dir())
    print(f"  worktrees: {', '.join(map(str, wts)) if wts else 'none'}")
    return 0


if __name__ == "__main__":
    code = main()
    print_warnings()
    sys.exit(code)
