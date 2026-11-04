#!/usr/bin/env bash
# Cut a release of workai-playbooks, or say whether one is due.
#
#   scripts/release.sh A.B.C     move [Unreleased] into a new CHANGELOG entry,
#                                write VERSION, commit "Release A.B.C", tag vA.B.C
#   scripts/release.sh --check   exit 1 if commits since the last tag are unreleased
#
# Rules (README "Versions and releases"): a change to any skill's SKILL.md
# since the last tag is a rule change and needs at least a minor bump; a
# major bump needs a "### Migration" section. Run on main, clean tree. It
# never pushes: `git push --follow-tags` is the user's call.
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
g() { git -C "$repo" "$@"; }
last="$(g tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
current="$(cat "$repo/VERSION")"

if [ "${1:-}" = "--check" ]; then
  [ -n "$last" ] || { echo "no release tag yet"; exit 1; }
  n="$(g rev-list --count "$last..HEAD")"
  [ "$n" = 0 ] && { echo "release: up to date ($last)"; exit 0; }
  rules="$(g diff --name-only "$last" HEAD -- 'skills/*/SKILL.md' | wc -l | tr -d ' ')"
  echo "release: $n commit(s) since $last, $rules skill rule file(s) changed; cut one with scripts/release.sh"
  exit 1
fi

new="${1:-}"
echo "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { sed -n '4,6p' "$0" | sed 's/^# *//'; exit 2; }
[ "$(g rev-parse --abbrev-ref HEAD)" = main ] || { echo "not on main"; exit 1; }
[ -z "$(g status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
g rev-parse -q --verify "refs/tags/v$new" >/dev/null && { echo "tag v$new exists"; exit 1; }

IFS=. read -r a b c <<<"$new"; IFS=. read -r oa ob oc <<<"${last#v}"
[ -n "$last" ] || { oa=0; ob=0; oc=0; }
if [ "$a" -gt "$oa" ]; then kind=major
elif [ "$a" -eq "$oa" ] && [ "$b" -gt "$ob" ]; then kind=minor
elif [ "$a" -eq "$oa" ] && [ "$b" -eq "$ob" ] && [ "$c" -gt "$oc" ]; then kind=patch
else echo "$new is not after ${last:-0.0.0}"; exit 1; fi
if [ -n "$last" ] && [ "$kind" = patch ] && [ -n "$(g diff --name-only "$last" HEAD -- 'skills/*/SKILL.md')" ]; then
  echo "skill rules changed since $last: a patch is not enough, use at least $a.$((b + 1)).0"
  exit 1
fi

python3 - "$repo/CHANGELOG.md" "$new" "$kind" "$(date +%F)" <<'EOF' || exit 1
import re, sys
path, new, kind, today = sys.argv[1:]
s = open(path).read()
m = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[)", s, re.M | re.S)
if not m or not m.group(1).strip():
    sys.exit("CHANGELOG.md: [Unreleased] is empty, nothing to release")
body = m.group(1).strip("\n")
if kind == "major" and "### Migration" not in body:
    sys.exit("CHANGELOG.md: a major release needs a ### Migration section")
entry = f"## [Unreleased]\n\n## [{new}] — {today}\n\n{body}\n\n"
open(path, "w").write(s[:m.start()] + entry + s[m.end():])
EOF
echo "$new" >"$repo/VERSION"
g add VERSION CHANGELOG.md
g commit -q -m "Release $new" || exit 1
g tag -a "v$new" -m "$new" || exit 1
echo "released v$new ($kind); not pushed. Live install: ./install.sh claude --release v$new"
