#!/usr/bin/env bash
# Tests for scripts/check-skills.py: the real skills pass, each broken skill fails.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/scripts/check-skills.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

expect() { # expected-exit description skills-dir
  python3 "$check" "$3" >"$tmp/out" 2>&1
  local got=$?
  if [ "$got" -eq "$1" ]; then
    echo "ok   $2"
  else
    echo "FAIL $2 (exit $got, expected $1)"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1))
  fi
}

broken() { # folder frontmatter-lines...
  local dir="$tmp/$1"; shift
  rm -rf "$dir"; mkdir -p "$dir/s"
  { echo "---"; printf '%s\n' "$@"; echo "---"; echo "# body"; } >"$dir/s/SKILL.md"
  echo "$dir"
}
rename() { mv "$1/s" "$1/$2"; echo "$1"; }

expect 0 "real skills pass" "$here/skills"

# --cards (card 01-108): duplicate card ids in a hub are rejected.
w="$tmp/ws"; mkdir -p "$w/projects/01-a/backlog/todo" "$w/projects/01-a/backlog/done" "$w/archives/02-b/backlog/todo"
printf -- '---\nid: 001\n---\n' >"$w/projects/01-a/backlog/todo/001-x.md"
printf -- '---\nid: 002\n---\n' >"$w/projects/01-a/backlog/done/002-y.md"
printf -- '---\nid: 001\n---\n' >"$w/archives/02-b/backlog/todo/001-z.md"
python3 "$check" --cards "$w" >"$tmp/out" 2>&1 && grep -q "2 hubs, 0 duplicate" "$tmp/out" \
  && echo "ok   --cards: same id in two hubs is fine" || { echo "FAIL --cards clean"; cat "$tmp/out"; fails=$((fails + 1)); }
printf -- '---\nid: 002\n---\n' >"$w/projects/01-a/backlog/todo/002-again.md"
python3 "$check" --cards "$w" >"$tmp/out" 2>&1
[ $? -eq 1 ] && grep -q "FAIL duplicate card id 01-a: 002 in todo/002-again.md, done/002-y.md" "$tmp/out" \
  && echo "ok   --cards: duplicate id in one hub fails, both files named" || { echo "FAIL --cards duplicate"; cat "$tmp/out"; fails=$((fails + 1)); }
expect 1 "missing name"           "$(rename "$(broken a 'description: x')" workai-a)"
expect 1 "name differs from folder" "$(rename "$(broken b 'name: workai-other' 'description: x')" workai-b)"
expect 1 "no workai- prefix"      "$(rename "$(broken c 'name: c' 'description: x')" c)"
expect 1 "agent-specific field"   "$(rename "$(broken d 'name: workai-d' 'description: x' 'allowed-tools: Bash')" workai-d)"
expect 1 "empty description"      "$(rename "$(broken e 'name: workai-e' 'description:')" workai-e)"
expect 1 "description too long"   "$(rename "$(broken f 'name: workai-f' "description: $(printf 'x%.0s' $(seq 1025))")" workai-f)"
expect 1 "uppercase name"         "$(rename "$(broken g 'name: workai-G' 'description: x')" workai-G)"
dir="$(rename "$(broken h 'name: workai-h' 'description: x')" workai-h)"
echo "[see](missing.md)" >>"$dir/workai-h/SKILL.md"
expect 1 "broken relative link" "$dir"
mkdir -p "$tmp/i/workai-i"; echo "# no frontmatter" >"$tmp/i/workai-i/SKILL.md"
expect 1 "no frontmatter" "$tmp/i"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
