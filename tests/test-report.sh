#!/usr/bin/env bash
# Tests for skills/workai-open-project/report.py on a fixture workai:
# the text report still runs, and --json returns every card with correct flags.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
report="$here/skills/workai-open-project/report.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
root="$tmp/workai"

card() { # hub status id depends [extra frontmatter lines...]
  local hub="$1" status="$2" id="$3" deps="$4"; shift 4
  mkdir -p "$root/$hub/backlog/$status"
  {
    echo "---"; echo "id: $id"; echo "title: \"Card $id\""; echo "repo: hub"
    echo "priority: 2"; echo "depends: [$deps]"
    printf '%s\n' "$@"
    echo "---"; echo "## Goal"; echo "Body of $id."
  } >"$root/$hub/backlog/$status/$id-card.md"
}

old="$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d)"
today="$(date +%Y-%m-%d)"
h1=projects/01-alpha
card $h1 done 001 "" "finished: $today"
card $h1 done 002 "" "finished: $old"
card $h1 todo 003 "001"
card $h1 todo 004 "5"
card $h1 todo 005 ""
card $h1 doing 006 "" "claimed_by: agent A" "waiting: question for the user"
card $h1 doing 007 "" "claimed_by: agent B"
touch -t 202001010000 "$root/$h1/backlog/doing/007-card.md"
card $h1 doing 008 "" "claimed_by: agent C"
card $h1 todo 009 "001, 099"
card $h1 archive 010 "" "finished: 2026-01-01"
card projects/02-beta todo 001 ""
card archives/03-gamma todo 001 ""
mkdir -p "$root/projects/not-a-hub"
# next.md: 7 valid entries (over the cap of 5), a duplicate, a bad line.
cat >"$root/next.md" <<'NEXT'
# Next: ordered, at most 5
02-001  # quick win
- 01-004  # blocked, unblock it
01-005
01-006  # claimed since
01-077
03-001
1. 01-003
01-005
not a label
NEXT
before="$(find "$root" -type f -exec shasum {} + | sort)"

check() { # description python-assertion (d = parsed JSON, c = cards by label)
  if python3 -c "
import json, sys
d = json.load(open('$tmp/out.json'))
c = {x['label']: x for x in d['cards']}
assert $2, 'assertion failed'
" 2>"$tmp/err"; then
    echo "ok   $1"
  else
    echo "FAIL $1"; sed 's/^/     /' "$tmp/err"; fails=$((fails + 1))
  fi
}

python3 "$report" 1 "$root" >"$tmp/out.txt"
if [ $? -eq 0 ] && grep -q "claimable (2)" "$tmp/out.txt" && grep -q "STALE" "$tmp/out.txt"; then
  echo "ok   text report still works"
else
  echo "FAIL text report"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi

python3 "$report" --json --all "$root" >"$tmp/out.json" || { echo "FAIL --json --all exit"; fails=$((fails + 1)); }
check "all project hubs, no archives, no non-hubs" "[h['number'] for h in d['hubs']] == ['01', '02']"
check "every card, labelled NN-NNN" "sorted(c) == ['01-%03d' % i for i in range(1, 11)] + ['02-001']"
check "status from the folder" "c['01-006']['status'] == 'doing' and c['01-010']['status'] == 'archive'"
check "claimable" "[l for l in c if c[l]['flags']['claimable']] == ['01-003', '01-005', '02-001']"
check "blocked, with blockers" "c['01-004']['flags']['blocked'] and c['01-004']['blocked_by'] == ['005']"
check "missing dependency blocks and is listed" "c['01-009']['flags']['blocked'] and c['01-009']['missing'] == ['099'] and c['01-009']['blocked_by'] == ['099']"
check "waiting" "c['01-006']['flags']['waiting'] and not c['01-006']['flags']['stale'] and c['01-006']['waiting'] == 'question for the user'"
check "stale" "c['01-007']['flags']['stale'] and not c['01-008']['flags']['stale']"
check "overdue" "c['01-002']['flags']['overdue'] and not c['01-001']['flags']['overdue'] and not c['01-010']['flags']['overdue']"
check "dependents" "c['01-001']['dependents'] == ['003', '009'] and c['01-005']['dependents'] == ['004'] and c['01-003']['dependents'] == []"
check "fields and body" "c['01-006']['claimed_by'] == 'agent A' and c['01-003']['title'] == 'Card 003' and c['01-003']['priority'] == 2 and c['01-003']['body'].startswith('## Goal')"
check "no git state by default" "'git' not in d['hubs'][0]"

check "next: order as in the file" "[e['label'] for e in d['next']['order']] == ['02-001', '01-004', '01-005', '01-006', '01-077', '03-001', '01-003'] and d['next']['order'][0]['reason'] == 'quick win'"
check "next: todo cards shown in order, blocked one kept" "d['next']['shown'] == ['02-001', '01-004', '01-005', '01-003'] and c['01-004']['flags']['blocked']"
check "next: place on each card" "c['02-001']['next'] == 1 and c['01-003']['next'] == 4 and c['01-009']['next'] is None and c['01-006']['next'] is None"
check "next: stale ids listed with why" "d['next']['stale'] == [{'label': '01-006', 'status': 'doing', 'reason': 'claimed since'}, {'label': '01-077', 'status': 'missing', 'reason': ''}, {'label': '03-001', 'status': 'archived hub', 'reason': ''}]"
check "next: over the cap warns, nothing dropped" "d['next']['over_cap'] and len(d['next']['order']) == 7 and any('cap is 5' in w for w in d['next']['warnings'])"
check "next: duplicate and bad line reported" "d['next']['duplicates'] == ['01-005'] and d['next']['invalid'] == ['line 10: not a label']"
python3 "$report" --json --all --archives "$root" >"$tmp/out.json"
check "--archives adds archived hubs" "[h['number'] for h in d['hubs']] == ['01', '02', '03'] and d['hubs'][2]['area'] == 'archives'"
python3 "$report" --json 2 "$root" >"$tmp/out.json"
check "one hub by number" "sorted(c) == ['02-001']"
check "one hub: only its Next entries" "[e['label'] for e in d['next']['order']] == ['02-001'] and d['next']['shown'] == ['02-001'] and not d['next']['over_cap']"
python3 "$report" --json --git 1 "$root" >"$tmp/out.json"
check "--git adds git state" "d['hubs'][0]['git']['hub'] == 'not a git repo'"

python3 "$report" --json 7 "$root" >/dev/null 2>&1
[ $? -eq 2 ] && echo "ok   unknown hub exits 2" || { echo "FAIL unknown hub exit"; fails=$((fails + 1)); }

after="$(find "$root" -type f -exec shasum {} + | sort)"
python3 "$report" 1 "$root" >"$tmp/out.txt"
if sed -n '/^claimable/,/^blocked/p' "$tmp/out.txt" | grep -E '^  [0-9]' | awk '{print $1}' | tr '\n' ' ' | grep -q '^005 003 $' \
   && grep -q "005 p2 Card 005 \[next\]" "$tmp/out.txt" && grep -q "in Next but blocked (unblock them): 004" "$tmp/out.txt" \
   && grep -q "stale in .*next.md (not in todo/, prune): 01-006, 01-077" "$tmp/out.txt" && grep -q "has 7 entries; the cap is 5" "$tmp/out.txt"; then
  echo "ok   text report: Next first in picking order, blocked/stale/cap lines"
else
  echo "FAIL text report Next"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
rm "$root/next.md"
python3 "$report" --json --all "$root" >"$tmp/out.json"
check "no next.md: empty Next, no warning" "not d['next']['exists'] and d['next']['order'] == [] and d['next']['warnings'] == [] and c['01-003']['next'] is None"
before="$(find "$root" -type f -exec shasum {} + | sort)"
python3 "$report" --json --all "$root" >/dev/null
after="$(find "$root" -type f -exec shasum {} + | sort)"
[ "$before" = "$after" ] && echo "ok   fixture unchanged (read-only)" || { echo "FAIL fixture changed"; fails=$((fails + 1)); }

# --waiting (card 01-090): waiting, then stale, then todo cards held only by waiting ones.
card $h1 todo 011 "006"
card $h1 todo 012 "006, 005"
python3 "$report" --waiting "$root" >"$tmp/out.txt"
if [ $? -eq 0 ] && grep -q "^waiting on you (1):$" "$tmp/out.txt" && grep -q "^  01-006  Card 006  (alpha)$" "$tmp/out.txt" \
   && grep -q "question: question for the user" "$tmp/out.txt" \
   && sed -n '/^stale/,/^blocked/p' "$tmp/out.txt" | grep -q "^  01-007  Card 007  (alpha)  \[agent B\]$" \
   && sed -n '/^blocked only/,$p' "$tmp/out.txt" | grep -q "^  01-011  .*blocked by 01-006$" \
   && ! grep -q "01-012" "$tmp/out.txt" && ! grep -q "03-001\|02-001" "$tmp/out.txt"; then
  echo "ok   --waiting: waiting, stale, blocked only by waiting (not by a todo card too)"
else
  echo "FAIL --waiting"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi

# Git failing (card 01-100): a `git` that exits non-zero must read "git failed",
# never "clean" or "no upstream", in the text report, --list and --json --git.
groot="$tmp/gitws"
mkdir -p "$groot/projects/01-alpha/backlog/todo" "$groot/projects/01-alpha/repos/r1"
git -C "$groot/projects/01-alpha" init -q
echo "repos/" >>"$groot/projects/01-alpha/.git/info/exclude"
git -C "$groot/projects/01-alpha/repos/r1" init -q
python3 "$report" 1 "$groot" >"$tmp/out.txt"
if grep -q "^  hub: clean, no upstream$" "$tmp/out.txt" && grep -q "^  repos/r1: clean, no upstream$" "$tmp/out.txt"; then
  echo "ok   real git: empty repos are clean, no upstream"
else
  echo "FAIL real git state"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "fatal: git blocked by sandbox" >&2\nexit 128\n' >"$tmp/fakebin/git"
chmod +x "$tmp/fakebin/git"
PATH="$tmp/fakebin:$PATH" python3 "$report" 1 "$groot" >"$tmp/out.txt"
if [ $? -eq 0 ] && grep -q "^  hub: git failed: fatal: git blocked by sandbox$" "$tmp/out.txt" \
   && grep -q "^  repos/r1: git failed: fatal: git blocked by sandbox$" "$tmp/out.txt" \
   && ! grep -qi "clean\|upstream" "$tmp/out.txt"; then
  echo "ok   failing git: text report says git failed, never clean"
else
  echo "FAIL failing git text report"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
PATH="$tmp/fakebin:$PATH" python3 "$report" --list "$groot" >"$tmp/out.txt"
if [ $? -eq 0 ] && grep -q "^    git: hub git failed: fatal: git blocked by sandbox; repos/r1 git failed: fatal: git blocked by sandbox$" "$tmp/out.txt" \
   && ! grep -qi "clean\|upstream" "$tmp/out.txt"; then
  echo "ok   failing git: --list says git failed, never clean"
else
  echo "FAIL failing git --list"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
PATH="$tmp/fakebin:$PATH" python3 "$report" --json --all --git "$groot" >"$tmp/out.json"
check "failing git: --json --git says git failed, lists where" "d['hubs'][0]['git']['hub'] == 'git failed: fatal: git blocked by sandbox' and d['hubs'][0]['git']['repos'] == {'r1': 'git failed: fatal: git blocked by sandbox'} and d['hubs'][0]['git']['failed'] == ['hub', 'repos/r1'] and 'clean' not in json.dumps(d['hubs'][0]['git'])"
PATH="$tmp/fakebin:$PATH" python3 "$report" --json 1 "$groot" >"$tmp/out.json"
check "failing git: --json without --git has no git state" "'git' not in d['hubs'][0]"
python3 "$report" --json --git 1 "$groot" >"$tmp/out.json"
check "real git: git.failed empty" "d['hubs'][0]['git']['failed'] == [] and d['hubs'][0]['git']['hub'] == 'clean, no upstream'"
# status works but rev-list fails for a reason other than a missing upstream
printf '#!/bin/sh\ncase "$*" in *rev-list*) echo "fatal: bad object HEAD" >&2; exit 128;; esac\nexec %s "$@"\n' "$(command -v git)" >"$tmp/fakebin/git"
PATH="$tmp/fakebin:$PATH" python3 "$report" 1 "$groot" >"$tmp/out.txt"
if grep -q "^  hub: clean, git failed: fatal: bad object HEAD$" "$tmp/out.txt" && ! grep -q "no upstream" "$tmp/out.txt"; then
  echo "ok   failing rev-list: not reported as no upstream"
else
  echo "FAIL failing rev-list"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
# git missing from PATH altogether
PATH="/nonexistent" "$(command -v python3)" "$report" 1 "$groot" >"$tmp/out.txt"
if grep -q "^  hub: git failed: " "$tmp/out.txt" && ! grep -qi "clean" "$tmp/out.txt"; then
  echo "ok   no git on PATH: git failed, no traceback"
else
  echo "FAIL no git on PATH"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi


# Robustness (card 01-112): unreadable cards, duplicate ids, deps and priority
# parsing, one flag source for text and JSON, failing git never STALE.
rroot="$tmp/rob"
rh="$rroot/projects/01-rob/backlog"
mkdir -p "$rh/todo" "$rh/doing" "$rh/done"
raw() { # status file, frontmatter lines on stdin after ---
  { echo "---"; cat; echo "---"; echo "## Goal"; echo "x"; } >"$rh/$1/$2"
}
printf 'id: 001\ntitle: "Done one"\npriority: 2\ndepends: []\nfinished: 2026-10-01\n' | raw done 001-a.md
printf 'id: 005\ntitle: "Done five"\npriority: 2\ndepends: []\nfinished: 2026-10-01\n' | raw done 005-a.md
printf 'id: 010\ntitle: "Unpadded dep on a done card"\npriority: 2\ndepends: [5]\n' | raw todo 010-a.md
printf 'id: 011\ntitle: "Cross-hub label"\npriority: 2\ndepends: [02-001]\n' | raw todo 011-a.md
printf 'id: 012\ntitle: "Comment after empty deps"\npriority: 2 # normal\ndepends: [] # nothing yet\n' | raw todo 012-a.md
printf 'id: 013\ntitle: "Comment mentions an id"\npriority: high\ndepends: [001] # after 099\n' | raw todo 013-a.md
printf 'id: 014\ntitle: "Block list"\npriority: low\ndepends:\n  - 001\n  - 099\n' | raw todo 014-a.md
printf 'id: 015\ntitle: "Self"\npriority: soon\ndepends: [015]\n' | raw todo 015-a.md
printf 'id: 016\ntitle: "Cycle a"\npriority: 2\ndepends: [017]\n' | raw todo 016-a.md
printf 'id: 017\ntitle: "Cycle b"\npriority: 2\ndepends: [16]\n' | raw todo 017-a.md
printf 'id: 018\ntitle: "Title with # inside"\npriority: 2\ndepends: []\n' | raw todo 018-a.md
printf "id: 019\ntitle: 'Ana''s # list'  # note\npriority: 2\ndepends: []\n" | raw todo 019-a.md
printf 'id: 020\ntitle: "Dup in todo"\npriority: 2\ndepends: []\n' | raw todo 020-first.md
printf 'id: 020\ntitle: "Dup in doing"\npriority: 2\ndepends: []\nclaimed_by: agent X\n' | raw doing 020-second.md
printf -- '---\nid: 021\ntitle: "Latin-1 \xe9t\xe9"\npriority: 2\ndepends: []\n---\n## Goal\n' >"$rh/todo/021-latin1.md"
ln -s "$rh/todo/nowhere.md" "$rh/todo/022-dangling.md"
mkdir -p "$rh/todo/023-a-directory.md"
python3 "$report" --json --all "$rroot" >"$tmp/out.json" 2>"$tmp/err.txt"
[ $? -eq 0 ] && echo "ok   bad cards: --json --all still exits 0" || { echo "FAIL bad cards --json exit"; cat "$tmp/err.txt"; fails=$((fails + 1)); }
check "bad cards: skipped with a warning, the rest kept" "'01-022' not in c and '01-023' not in c and '01-010' in c and any('022-dangling.md' in w and 'skipped' in w for w in d['warnings']) and any('023-a-directory.md' in w for w in d['warnings'])"
check "non-UTF-8 card kept, warned" "c['01-021']['title'].startswith('Latin-1') and any('021-latin1.md' in w and 'UTF-8' in w for w in d['warnings'])"
check "duplicate ids: both kept, flagged, warned" "sorted(x['path'].rsplit('/', 2)[-2] for x in d['cards'] if x['label'] == '01-020') == ['doing', 'todo'] and all(x['flags']['duplicate'] for x in d['cards'] if x['label'] == '01-020') and not c['01-010']['flags']['duplicate'] and any('duplicate card id 01-020' in w for w in d['warnings'])"
check "deps: unpadded id on a done card is claimable" "c['01-010']['depends'] == ['005'] and c['01-010']['flags']['claimable']"
check "deps: cross-hub label is invalid, blocks, not read as 002,001" "c['01-011']['depends'] == [] and c['01-011']['invalid_depends'] == ['02-001'] and c['01-011']['flags']['blocked'] and any('02-001' in w for w in d['warnings'])"
check "deps: comment after [] stripped" "c['01-012']['depends'] == [] and c['01-012']['flags']['claimable']"
check "deps: ids in a comment ignored" "c['01-013']['depends'] == ['001'] and c['01-013']['flags']['claimable']"
check "deps: block-style list" "c['01-014']['depends'] == ['001', '099'] and c['01-014']['missing'] == ['099'] and c['01-014']['flags']['blocked']"
check "deps: self-dependency flagged" "c['01-015']['flags']['cycle'] and c['01-015']['dep_problems'] == ['depends on itself']"
check "deps: cycle flagged on both" "c['01-016']['flags']['cycle'] and c['01-017']['flags']['cycle'] and c['01-017']['depends'] == ['016'] and 'dependency cycle: 016 -> 017 -> 016' in c['01-016']['dep_problems'] and not c['01-010']['flags']['cycle']"
check "priority: comment, words, unreadable" "c['01-012']['priority'] == 2 and c['01-013']['priority'] == 1 and c['01-014']['priority'] == 3 and c['01-015']['priority'] is None and any(\"'soon'\" in w for w in d['warnings'])"
check "quoted value keeps its #" "c['01-018']['title'] == 'Title with # inside'"
check "single-quoted value: quotes off, '' is ', # kept" "c['01-019']['title'] == \"Ana's # list\""
python3 "$report" 1 "$rroot" >"$tmp/out.txt" 2>"$tmp/err.txt"
if [ $? -eq 0 ] && sed -n '/^claimable/,/^blocked/p' "$tmp/out.txt" | grep -q "^  010 " \
   && sed -n '/^claimable/,/^blocked/p' "$tmp/out.txt" | grep -q "^  013 p1 " \
   && ! sed -n '/^claimable/,/^blocked/p' "$tmp/out.txt" | grep -q "^  011 \|^  015 " \
   && grep -q "^  015 depends: depends on itself$" "$tmp/out.txt" \
   && grep -q "duplicate card ids (renumber one of each): 020" "$tmp/out.txt" \
   && grep -q "warning: skipped unreadable card .*022-dangling.md" "$tmp/err.txt"; then
  echo "ok   text report: same flags as JSON, bad priority no crash, problems and warnings shown"
else
  echo "FAIL text report robustness"; sed 's/^/     /' "$tmp/out.txt" "$tmp/err.txt"; fails=$((fails + 1))
fi
python3 "$report" --list "$rroot" >"$tmp/out.txt" 2>/dev/null && python3 "$report" --waiting "$rroot" >>"$tmp/out.txt" 2>/dev/null
[ $? -eq 0 ] && grep -q "doing: 020 Dup in doing" "$tmp/out.txt" && echo "ok   bad cards: --list and --waiting still work" || { echo "FAIL bad cards --list/--waiting"; fails=$((fails + 1)); }

# Failing git never yields STALE: an old doing card on a branch of a real repo.
sroot="$tmp/stale"
sh="$sroot/projects/01-s"
mkdir -p "$sh/backlog/doing" "$sh/repos/r1"
git -C "$sh/repos/r1" init -q
printf -- '---\nid: 001\ntitle: "Old"\nrepo: r1\npriority: 2\ndepends: []\nclaimed_by: agent Y\nbranch: card/001-old\nworktree: worktrees/r1/001-old\n---\n' >"$sh/backlog/doing/001-old.md"
touch -t 202001010000 "$sh/backlog/doing/001-old.md"
python3 "$report" --json 1 "$sroot" >"$tmp/out.json"
check "working git, branch gone, old card: STALE" "c['01-001']['flags']['stale'] and not c['01-001']['flags']['activity_unknown']"
printf '#!/bin/sh\necho "fatal: git blocked by sandbox" >&2\nexit 128\n' >"$tmp/fakebin/git"
PATH="$tmp/fakebin:$PATH" python3 "$report" --json 1 "$sroot" >"$tmp/out.json"
check "failing git: never STALE, activity unknown" "not c['01-001']['flags']['stale'] and c['01-001']['flags']['activity_unknown'] and c['01-001']['last_activity'] is None"
PATH="$tmp/fakebin:$PATH" python3 "$report" 1 "$sroot" >"$tmp/out.txt"
PATH="$tmp/fakebin:$PATH" python3 "$report" --list "$sroot" >>"$tmp/out.txt"
PATH="$tmp/fakebin:$PATH" python3 "$report" --waiting "$sroot" >>"$tmp/out.txt"
if ! grep -q "STALE" "$tmp/out.txt" && grep -q "activity unknown (git failed)" "$tmp/out.txt" && grep -q "^stale, no activity for 24h (0):" "$tmp/out.txt"; then
  echo "ok   failing git: text, --list, --waiting show no STALE"
else
  echo "FAIL failing git STALE"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi


# due: (card 01-107): open cards due within 14 days or past due come first.
day() { date -v"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 days" +%Y-%m-%d; }
droot="$tmp/due"
dh="$droot/projects/01-due/backlog"
mkdir -p "$dh/todo" "$dh/doing" "$dh/done" "$droot/projects/02-other/backlog/todo"
printf -- "---\nid: 001\ntitle: \"Court\"\npriority: 2\ndepends: []\ndue: $(day +3)\n---\n" >"$dh/todo/001-court.md"
printf -- "---\nid: 002\ntitle: \"Missed\"\npriority: 2\ndepends: []\ndue: $(day -2)\nclaimed_by: agent Z\n---\n" >"$dh/doing/002-missed.md"
printf -- "---\nid: 003\ntitle: \"Far\"\npriority: 2\ndepends: []\ndue: $(day +40)\n---\n" >"$dh/todo/003-far.md"
printf -- "---\nid: 004\ntitle: \"Done late\"\npriority: 2\ndepends: []\ndue: $(day -5)\nfinished: $today\n---\n" >"$dh/done/004-done.md"
printf -- "---\nid: 005\ntitle: \"Bad date\"\npriority: 2\ndepends: []\ndue: next week\n---\n" >"$dh/todo/005-bad.md"
printf -- "---\nid: 006\ntitle: \"Today\"\npriority: 3\ndepends: [9]\ndue: $today\n---\n" >"$dh/todo/006-today.md"
printf -- "---\nid: 001\ntitle: \"Other hub soon\"\npriority: 2\ndepends: []\ndue: $(day +14)\n---\n" >"$droot/projects/02-other/backlog/todo/001-soon.md"
python3 "$report" --json --all "$droot" >"$tmp/out.json" 2>/dev/null
check "due: date and days" "c['01-001']['due'] == '$(day +3)' and c['01-001']['due_in_days'] == 3 and c['01-002']['due_in_days'] == -2 and c['01-003']['due_in_days'] == 40"
check "due: due_soon within 14 days, past_due before today, never for done" "c['01-001']['flags']['due_soon'] and c['02-001']['flags']['due_soon'] and c['01-006']['flags']['due_soon'] and not c['01-003']['flags']['due_soon'] and c['01-002']['flags']['past_due'] and not c['01-002']['flags']['due_soon'] and not c['01-004']['flags']['past_due'] and not c['01-004']['flags']['due_soon']"
check "due: unreadable date warned, no flag" "c['01-005']['due'] == '' and c['01-005']['due_in_days'] is None and not c['01-005']['flags']['due_soon'] and any(\"'next week'\" in w for w in d['warnings'])"
check "due: no due field, no flags" "c['01-001']['flags']['overdue'] is False and 'due' in c['01-001']"
python3 "$report" --waiting "$droot" >"$tmp/out.txt" 2>/dev/null
if [ "$(head -1 "$tmp/out.txt")" = "due within 14 days or past due (4):" ] \
   && [ "$(sed -n '2,9p' "$tmp/out.txt" | grep -E '^  [0-9]' | awk '{print $1}' | tr '\n' ' ')" = "01-002 01-006 01-001 02-001 " ] \
   && grep -q "^  01-002  Missed  (due)  PAST DUE $(day -2) (2 days ago)  \[doing\]$" "$tmp/out.txt" \
   && grep -q "01-006  Today .*due $today (TODAY)" "$tmp/out.txt" \
   && grep -q "01-001  Court .*due $(day +3) (in 3 days)  \[todo\]" "$tmp/out.txt" \
   && ! grep -q "01-003\|01-004\|01-005" "$tmp/out.txt" && grep -q "^waiting on you (0):" "$tmp/out.txt"; then
  echo "ok   --waiting: due cards first, soonest first, past due flagged"
else
  echo "FAIL --waiting due"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
python3 "$report" --list "$droot" >"$tmp/out.txt" 2>/dev/null
python3 "$report" 1 "$droot" >>"$tmp/out.txt" 2>/dev/null
if grep -q "^    PAST DUE $(day -2) (2 days ago): 002 Missed \[doing\]$" "$tmp/out.txt" \
   && grep -q "^    due $(day +14) (in 14 days): 001 Other hub soon \[todo\]$" "$tmp/out.txt" \
   && grep -q "^due within 14 days or past due:$" "$tmp/out.txt" && grep -q "^  001 Court \[todo\] due $(day +3) (in 3 days)$" "$tmp/out.txt"; then
  echo "ok   --list and the hub report show due cards"
else
  echo "FAIL --list/hub due"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi


# youtrack: groups (card 01-147): once a hub has one, open cards without one are flagged.
groot="$tmp/groups"
gh="$groot/projects/01-grouped/backlog"
mkdir -p "$gh/todo" "$gh/doing" "$gh/done" "$groot/projects/02-plain/backlog/todo"
printf -- "---\nid: 001\ntitle: \"In a group\"\npriority: 2\ndepends: []\nyoutrack: H01-3\n---\n" >"$gh/todo/001-a.md"
printf -- "---\nid: 002\ntitle: \"Loose todo\"\npriority: 2\ndepends: []\n---\n" >"$gh/todo/002-b.md"
printf -- "---\nid: 003\ntitle: \"Loose doing\"\npriority: 2\ndepends: []\nclaimed_by: agent Z\n---\n" >"$gh/doing/003-c.md"
printf -- "---\nid: 004\ntitle: \"Old done\"\npriority: 2\ndepends: []\nfinished: $today\n---\n" >"$gh/done/004-d.md"
printf -- "---\nid: 001\ntitle: \"Hub without groups\"\npriority: 2\ndepends: []\n---\n" >"$groot/projects/02-plain/backlog/todo/001-x.md"
python3 "$report" --json --all "$groot" >"$tmp/out.json" 2>/dev/null
check "youtrack: field read" "c['01-001']['youtrack'] == 'H01-3' and c['01-002']['youtrack'] == ''"
check "youtrack: open cards without a group flagged in a grouped hub" "c['01-002']['flags']['ungrouped'] and c['01-003']['flags']['ungrouped'] and not c['01-001']['flags']['ungrouped']"
check "youtrack: done cards and hubs without groups never flagged" "not c['01-004']['flags']['ungrouped'] and not c['02-001']['flags']['ungrouped']"
python3 "$report" 1 "$groot" >"$tmp/out.txt" 2>/dev/null
python3 "$report" 2 "$groot" >"$tmp/out2.txt" 2>/dev/null
if grep -q "^without a group (no youtrack:): 002, 003$" "$tmp/out.txt" && ! grep -q "without a group" "$tmp/out2.txt"; then
  echo "ok   hub report lists cards without a group"
else
  echo "FAIL hub report groups"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi
python3 "$report" --card 01-001 "$groot" >"$tmp/out.txt" 2>/dev/null
python3 "$report" --card 01-002 "$groot" >"$tmp/out2.txt" 2>/dev/null
if grep -q "^group: H01-3 (YouTrack)$" "$tmp/out.txt" && ! grep -q "^group:" "$tmp/out2.txt"; then
  echo "ok   --card shows the card's group"
else
  echo "FAIL --card group"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi


# Old waiting cards (card 01-109): waiting more than 7 days is flagged.
wroot="$tmp/wait"
wh="$wroot/projects/01-wait/backlog/doing"
mkdir -p "$wh"
printf -- "---\nid: 001\ntitle: \"Asked long ago\"\npriority: 2\ndepends: []\nstarted: $(day -30) 10:00\nwaiting: question, see Notes\nwaiting_since: $(day -8)\n---\n" >"$wh/001-a.md"
printf -- "---\nid: 002\ntitle: \"Asked this week\"\npriority: 2\ndepends: []\nstarted: $(day -30) 10:00\nwaiting: question, see Notes\nwaiting_since: $(day -7)\n---\n" >"$wh/002-b.md"
printf -- "---\nid: 003\ntitle: \"No since, old claim\"\npriority: 2\ndepends: []\nstarted: $(day -9) 10:00\nwaiting: question, see Notes\n---\n" >"$wh/003-c.md"
printf -- "---\nid: 004\ntitle: \"No dates\"\npriority: 2\ndepends: []\nwaiting: question, see Notes\n---\n" >"$wh/004-d.md"
printf -- "---\nid: 005\ntitle: \"Not waiting, old\"\npriority: 2\ndepends: []\nstarted: $(day -9) 10:00\n---\n" >"$wh/005-e.md"
python3 "$report" --json --all "$wroot" >"$tmp/out.json"
check "waiting_old: since waiting_since, > 7 days" "c['01-001']['flags']['waiting_old'] and c['01-001']['waiting_days'] == 8 and not c['01-002']['flags']['waiting_old'] and c['01-002']['waiting_days'] == 7"
check "waiting_old: falls back to started; unknown is not old; only waiting cards" "c['01-003']['flags']['waiting_old'] and c['01-004']['waiting_days'] is None and not c['01-004']['flags']['waiting_old'] and not c['01-005']['flags']['waiting_old'] and c['01-005']['waiting_days'] is None"
python3 "$report" --waiting "$wroot" >"$tmp/out.txt"
python3 "$report" 1 "$wroot" >>"$tmp/out.txt"
if grep -q "^  01-001  Asked long ago  (wait)  waiting 8 days, OLD: ask again or release$" "$tmp/out.txt" \
   && grep -q "^  01-002  Asked this week  (wait)  waiting 7 days$" "$tmp/out.txt" \
   && grep -q "^  01-004  No dates  (wait)$" "$tmp/out.txt" \
   && grep -q "^  001 Asked long ago .* WAITING (OLD: waiting 8 days): question, see Notes$" "$tmp/out.txt"; then
  echo "ok   --waiting and the hub report flag old waiting cards"
else
  echo "FAIL old waiting text"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi


# --index (card 01-106): the compact generated workai index.
iroot="$tmp/index"
mkhub() { # area dir title goal [extra README lines]
  mkdir -p "$iroot/$1/$2/backlog/todo" "$iroot/$1/$2/repos"
  printf '# %s — %s\n\nProject hub.\n\n## Goal\n\n%s\n%s\n' "${2%%-*}" "$3" "$4" "${5:-}" >"$iroot/$1/$2/README.md"
}
mkhub projects 07-cars "Coches" "Vehicles: Jimny (1618JBH) and MX-5 2118 NMC, NIE Y1234567C, call +34 600 123 456 or a@b.com. Second sentence."
mkhub projects 03-music "My Music" "<!-- aliases: vinyl, discogs -->
Favourite music." "- Migrated (was \`projects/music\`, old number L37)."
mkhub projects 12-secret "Secret" "Ghostwriting for Jane Doe: a book." "<!-- index: Ghostwriting a memoir. -->"
mkhub archives 02-old "Old Thing" "Something finished long ago, with a very long goal sentence that goes on and on and on well past the one hundred character limit."
mkdir -p "$iroot/projects/03-music/repos/my-music" "$iroot/projects/not-a-hub"
python3 "$report" --index "$iroot" >"$tmp/out.txt"
size=$(wc -c <"$tmp/out.txt")
if [ $? -eq 0 ] && head -1 "$tmp/out.txt" | grep -q "^# Workai index$" && grep -q "^## Active (3)$" "$tmp/out.txt" && grep -q "^## Archived (1)$" "$tmp/out.txt" \
   && [ "$(grep -E '^- \*\*' "$tmp/out.txt" | cut -c5-6 | tr '\n' ' ')" = "03 07 12 02 " ] \
   && grep -qx -- '- \*\*03 My Music\*\* (was L37): Favourite music. `projects/03-music/` repos: my-music' "$tmp/out.txt" \
   && grep -qx -- '- \*\*07 Coches\*\*: Vehicles: Jimny and MX-5, NIE, call or. `projects/07-cars/`' "$tmp/out.txt" \
   && ! grep -q "vinyl\|discogs\|aliases" "$tmp/out.txt" \
   && ! grep -q "1618JBH\|2118\|Y1234567C\|600 123\|a@b.com\|Jane Doe" "$tmp/out.txt" \
   && grep -q "^- \*\*12 Secret\*\*: Ghostwriting a memoir. " "$tmp/out.txt" \
   && grep -q "^- \*\*02 Old Thing\*\*: Something finished .*…" "$tmp/out.txt" && ! grep -q "not-a-hub" "$tmp/out.txt" \
   && [ "$size" -lt 10240 ]; then
  echo "ok   --index: header, one sorted line per hub, override, identifiers scrubbed, small"
else
  echo "FAIL --index"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1))
fi


# scripts/split-index.py (card 01-106): old index entries saved into their hubs.
printf '# Old\n\n## Instructions\nx\n\n## 03 — My Music (was L37)\nstate of music\n\n## L37 — note\nmore music\n\n## 99 — Gone\nlost\n' >"$iroot/CLAUDE.md"
python3 "$here/scripts/split-index.py" "$iroot" >"$tmp/out.txt"; code=$?
[ ! -e "$iroot/projects/03-music/notes" ] && [ $code -eq 1 ] && grep -q "UNMAPPED '99 — Gone'" "$tmp/out.txt" \
  && echo "ok   split-index: dry run writes nothing, unmapped numbered section fails" || { echo "FAIL split-index dry run"; cat "$tmp/out.txt"; fails=$((fails + 1)); }
python3 "$here/scripts/split-index.py" --write "$iroot" >"$tmp/out.txt"
f="$(ls "$iroot"/projects/03-music/notes/workai-index-entry-*.md 2>/dev/null)"
[ -n "$f" ] && grep -q "^state of music$" "$f" && grep -q "^more music$" "$f" && grep -q "wrote 1 file" "$tmp/out.txt" \
  && echo "ok   split-index --write: sections saved into the hub, two into one file" || { echo "FAIL split-index --write"; cat "$tmp/out.txt"; fails=$((fails + 1)); }

# WORKAI_ROOT environment variable (card 01-140): honoured in every mode when
# no positional root is given; a positional root wins. HOME points at an empty
# folder so a fallback to ~/workai would find nothing.
eroot="$tmp/envroot"
mkdir -p "$eroot/projects/01-envhub/backlog/todo" "$tmp/nohome"
printf '# Env hub\n\n## Goal\nOnly reachable through WORKAI_ROOT.\n' >"$eroot/projects/01-envhub/README.md"
HOME="$tmp/nohome" WORKAI_ROOT="$eroot" python3 "$report" 1 >"$tmp/out.txt"; code=$?
[ $code -eq 0 ] && [ "$(head -1 "$tmp/out.txt")" = "hub: $eroot/projects/01-envhub" ] \
  && echo "ok   WORKAI_ROOT: report.py 1 reports the env root's hub" || { echo "FAIL WORKAI_ROOT text report (exit $code)"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }
HOME="$tmp/nohome" WORKAI_ROOT="$eroot" python3 "$report" 1 "$root" >"$tmp/out.txt"; code=$?
[ $code -eq 0 ] && [ "$(head -1 "$tmp/out.txt")" = "hub: $root/projects/01-alpha" ] \
  && echo "ok   WORKAI_ROOT: a positional root wins" || { echo "FAIL WORKAI_ROOT positional (exit $code)"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }
HOME="$tmp/nohome" WORKAI_ROOT="$eroot" python3 "$report" --list >"$tmp/out.txt" \
  && grep -q "Env hub" "$tmp/out.txt" \
  && HOME="$tmp/nohome" WORKAI_ROOT="$eroot" python3 "$report" --json --all >"$tmp/out.json" \
  && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert [h['path'] for h in d['hubs']]==[sys.argv[2]], d" "$tmp/out.json" "$eroot/projects/01-envhub" 2>"$tmp/err" \
  && HOME="$tmp/nohome" WORKAI_ROOT="$eroot" python3 "$report" --waiting >/dev/null \
  && HOME="$tmp/nohome" WORKAI_ROOT="$eroot" python3 "$report" --index | grep -q "01 Env hub" \
  && echo "ok   WORKAI_ROOT: --list, --json --all, --waiting, --index use it" || { echo "FAIL WORKAI_ROOT other modes"; sed 's/^/     /' "$tmp/out.txt" "$tmp/err"; fails=$((fails + 1)); }
HOME="$tmp/nohome" WORKAI_ROOT="" python3 "$report" 1 >"$tmp/out.txt"; code=$?
[ $code -eq 2 ] && grep -q "$tmp/nohome/workai" "$tmp/out.txt" \
  && echo "ok   WORKAI_ROOT empty: falls back to ~/workai" || { echo "FAIL WORKAI_ROOT empty (exit $code)"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }

# Parked cards (card 01-179): backlog/parked/ is wanted but not now. Never
# claimable or stale, shown apart in every mode, a Next entry pointing at one
# is stale, and a card depending on it is blocked.
proot="$root"; root="$tmp/parkroot"
card projects/04-park parked 001 "" "claimed_by:" "started: 2020-01-01 00:00" "due: 2020-01-01"
touch -t 202001010000 "$root/projects/04-park/backlog/parked/001-card.md"
card projects/04-park todo 002 "001" "youtrack: H04-1"
card projects/04-park todo 003 "" "youtrack: H04-1"
printf '04-001  # parked\n04-003\n' >"$root/next.md"
python3 "$report" --json --all "$root" >"$tmp/out.json" || { echo "FAIL parked: --json exit"; fails=$((fails + 1)); }
check "parked: status from the folder, flag set" "c['04-001']['status'] == 'parked' and c['04-001']['flags']['parked']"
check "parked: not claimable, not blocked, not stale, not due, not ungrouped" "not any(c['04-001']['flags'][k] for k in ('claimable', 'blocked', 'stale', 'waiting', 'due_soon', 'past_due', 'activity_unknown', 'ungrouped'))"
check "parked: a card depending on it is blocked" "c['04-002']['flags']['blocked'] and c['04-002']['blocked_by'] == ['001'] and not c['04-002']['flags']['claimable']"
check "parked: its Next entry is stale (status parked), the other is shown" "d['next']['shown'] == ['04-003'] and d['next']['stale'] == [{'label': '04-001', 'status': 'parked', 'reason': 'parked'}] and c['04-001']['next'] is None"
python3 "$report" 4 "$root" >"$tmp/out.txt"
grep -q "^claimable (1)" "$tmp/out.txt" && grep -A1 "^parked (1), not now" "$tmp/out.txt" | grep -q "  001 p2 Card 001" \
  && grep -q "stale in .*next.md (not in todo/, prune): 04-001" "$tmp/out.txt" && ! grep -q "^due within" "$tmp/out.txt" \
  && echo "ok   parked: hub report lists it apart, not claimable, Next entry stale" || { echo "FAIL parked hub report"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }
python3 "$report" --list "$root" >"$tmp/out.txt"
grep -q "    parked (1): 001" "$tmp/out.txt" && echo "ok   parked: --list counts it" || { echo "FAIL parked --list"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }
python3 "$report" --waiting "$root" >"$tmp/out.txt"
grep -A1 "^parked, not now (1):" "$tmp/out.txt" | grep -q "04-001  Card 001" && grep -q "^due within 14 days or past due (0)" "$tmp/out.txt" \
  && grep -q "^stale, no activity for 24h (0)" "$tmp/out.txt" \
  && echo "ok   parked: --waiting shows it apart, never due or stale" || { echo "FAIL parked --waiting"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }
python3 "$report" --card 04-001 "$root" >"$tmp/out.txt"
grep -q "^status: parked: not now, never claimable" "$tmp/out.txt" && echo "ok   parked: --card says parked" || { echo "FAIL parked --card"; sed 's/^/     /' "$tmp/out.txt"; fails=$((fails + 1)); }
root="$proot"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
