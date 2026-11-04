#!/usr/bin/env bash
# Create a numbered project hub in workai, local only (no GitHub).
#
#   new-project.sh NAME "Title"     e.g. new-project.sh home-gym "Home Gym"
#
# NAME is lowercase kebab-case. The number is the highest NN- across
# projects/ and archives/, plus one. WORKAI_ROOT overrides ~/workai (tests).
# Then adds the hub to the workai .gitignore and regenerates the workai index
# (CLAUDE.md) with regen-index.sh, under the shared-file lock, and commits both.
# NO_REGISTER=1 skips both (used by workai-migrate, which registers at its end).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="${WORKAI_ROOT:-$HOME/workai}"
name="${1:-}"; title="${2:-}"

[ -n "$name" ] && [ -n "$title" ] || { sed -n '4,5p' "$0" | sed 's/^# *//'; exit 2; }
echo "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || { echo "name must be lowercase kebab-case: $name"; exit 2; }
# The title goes into headings and the workai index: one line, printable, short.
python3 - "$title" <<'EOF' || exit 2
import sys, unicodedata
t = sys.argv[1]
problem = ("is empty" if not t.strip() else
           "has a line break or control character" if any(unicodedata.category(c)[0] == "C" for c in t) else
           "starts or ends with a space" if t != t.strip() else
           "starts with #" if t.startswith("#") else
           "is longer than 80 characters" if len(t) > 80 else "")
if problem:
    print(f"title {problem}: {t!r}")
    sys.exit(1)
EOF
[ -d "$root/projects" ] || { echo "no $root/projects"; exit 2; }

for existing in "$root"/projects/[0-9][0-9]-"$name" "$root"/archives/[0-9][0-9]-"$name"; do
  [ -e "$existing" ] && { echo "a hub named $name already exists: $existing"; exit 1; }
done

last="$(ls -d "$root"/projects/[0-9][0-9]-* "$root"/archives/[0-9][0-9]-* 2>/dev/null \
  | sed -E 's|.*/([0-9]{2})-.*|\1|' | sort -n | tail -1)"
num="$(printf '%02d' $((10#${last:-0} + 1)))"
[ "$num" -le 99 ] || { echo "no project numbers left"; exit 1; }
hub="$root/projects/$num-$name"
structure="$(cat "$here/../../VERSION")"
today="$(date +%F)"

# From here on a failure must not leave a half-made hub behind: remove it
# until its first commit exists (the hub did not exist before this run).
made=0
cleanup() { [ "$made" = 1 ] || { rm -rf "$hub"; echo "failed; removed the half-made $hub" >&2; }; }
trap cleanup EXIT
mkdir -p "$hub"/backlog/{todo,doing,done,archive} "$hub"/notes "$hub"/repos "$hub"/worktrees
for d in todo doing done archive; do touch "$hub/backlog/$d/.gitkeep"; done
touch "$hub/notes/.gitkeep"
# One pass over the template: a title containing DATE or NN stays as typed.
fill() {
  python3 - "$1" "$2" "$num" "$title" "$today" <<'EOF'
import re, sys
src, dst, num, title, today = sys.argv[1:]
values = {"NN": num, "TITLE": title, "DATE": today}
text = open(src, encoding="utf-8").read()
open(dst, "w", encoding="utf-8").write(re.sub(r"\b(NN|TITLE|DATE)\b", lambda m: values[m.group(1)], text))
EOF
}
fill "$here/template/README.md" "$hub/README.md"
fill "$here/template/CLAUDE.md" "$hub/CLAUDE.md"
cp "$here/template/backlog/README.md" "$here/template/backlog/TEMPLATE.md" "$hub/backlog/"
cp "$here/template/gitignore" "$hub/.gitignore"
echo "$structure" >"$hub/STRUCTURE"

git -C "$hub" init -q -b main
git -C "$hub" add -A
git -C "$hub" commit -q -m "Start hub for $num $title"
made=1
# Every later push is scanned for secrets and identity documents.
bash "$here/install-scan-hook.sh" "$hub" >/dev/null

# Register in workai: ignored by the workai repo, listed in its generated
# index (report.py --index regenerates the whole CLAUDE.md; never a hand entry).
if [ "${NO_REGISTER:-0}" = 1 ]; then echo "$hub"; exit 0; fi
grep -qxF "projects/$num-$name/" "$root/.gitignore" 2>/dev/null || echo "projects/$num-$name/" >>"$root/.gitignore"
if ! bash "$here/../workai-open-project/regen-index.sh" "Add hub $num $title to the index" >&2; then
  echo "hub made, but the index was not regenerated: run regen-index.sh (workai-open-project)" >&2
  echo "$hub"; exit 1
fi

echo "$hub"
