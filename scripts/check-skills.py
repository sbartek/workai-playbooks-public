#!/usr/bin/env python3
"""Static checks for skills: no agent is run, so this is fast and free.

Usage: scripts/check-skills.py [SKILLS_DIR]   (default: skills/ next to scripts/)
Exits 1 if any skill breaks a rule from the README's "Skill format" section.

       scripts/check-skills.py --cards [WORKAI_ROOT]   (default: ~/workai)
Checks every hub's backlog (projects/ and archives/) for two card files with
the same id; exits 1 and names them if there are any (git and concurrency
policy, workai-structure skill). Uses report.py's card reader.
"""
import re
import sys
from pathlib import Path

ALLOWED_KEYS = {"name", "description"}
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
LINK_RE = re.compile(r"\]\(([^)\s]+)\)")


def parse_frontmatter(text):
    """Return (dict, body) for a '---' delimited block of 'key: value' lines."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        raise ValueError("does not start with a '---' frontmatter line")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise ValueError("frontmatter is not closed with '---'")
    fields = {}
    for raw in lines[1:end]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw[0] in " \t":
            raise ValueError(f"nested or continued value not allowed: {raw.strip()!r}")
        key, sep, value = raw.partition(":")
        if not sep:
            raise ValueError(f"not a 'key: value' line: {raw!r}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        fields[key.strip()] = value
    return fields, "\n".join(lines[end + 1:])


def check_skill(skill_dir):
    errors = []
    skill_file = skill_dir / "SKILL.md"
    if not skill_file.is_file():
        return ["missing SKILL.md"]
    try:
        fields, body = parse_frontmatter(skill_file.read_text())
    except ValueError as e:
        return [f"frontmatter: {e}"]

    extra = set(fields) - ALLOWED_KEYS
    if extra:
        errors.append(f"agent-specific or unknown fields: {', '.join(sorted(extra))}")

    name = fields.get("name", "")
    if not name:
        errors.append("name is missing")
    else:
        if name != skill_dir.name:
            errors.append(f"name {name!r} does not match folder {skill_dir.name!r}")
        if not name.startswith("workai-"):
            errors.append(f"name {name!r} lacks the workai- prefix")
        if not NAME_RE.match(name) or len(name) > 64:
            errors.append(f"name {name!r} is not lowercase kebab-case of at most 64 characters")

    description = fields.get("description", "")
    if not 1 <= len(description) <= 1024:
        errors.append(f"description must be 1-1024 characters (has {len(description)})")

    for target in LINK_RE.findall(body):
        if re.match(r"^[a-z]+:", target) or target.startswith("#"):
            continue
        path = target.split("#", 1)[0]
        if path.startswith("/") or path.startswith("~"):
            errors.append(f"absolute link {target!r}")
        elif not (skill_dir / path).exists():
            errors.append(f"broken link {target!r}")
    return errors


def check_cards(args):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "skills" / "workai-open-project"))
    import report
    root = Path(args[0]) if args else Path.home() / "workai"
    if not (root / "projects").is_dir():
        print(f"not a workai root (no projects/): {root}")
        return 2
    hubs = report.all_hubs(root)
    dups = []
    for hub, _ in hubs:
        seen = {}
        for i, status, p, _, _ in report.hub_cards(hub):
            seen.setdefault(i, []).append(f"{status}/{p.name}")
        dups += [f"{hub.name}: {i} in {', '.join(w)}" for i, w in sorted(seen.items()) if len(w) > 1]
    for w in report.WARNINGS:
        if not w.startswith("duplicate card id"):
            print(f"warning: {w}")
    for d in dups:
        print(f"FAIL duplicate card id {d}")
    print(f"{len(hubs)} hubs, {len(dups)} duplicate card id(s)")
    return 1 if dups else 0


def main():
    if sys.argv[1:2] == ["--cards"]:
        return check_cards(sys.argv[2:])
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "skills"
    skills = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
    if not skills:
        print(f"no skills found in {root}")
        return 1
    failed = 0
    for skill in skills:
        errors = check_skill(skill)
        if errors:
            failed += 1
            print(f"FAIL {skill.name}")
            for e in errors:
                print(f"     {e}")
        else:
            print(f"ok   {skill.name}")
    print(f"{len(skills) - failed}/{len(skills)} skills pass")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
