#!/usr/bin/env bash
# Tests for report.py --list and open-by-name, against the eval fixture
# (evals/_fixtures/workai.sh + fixture_more_hubs + fixture_merged_hubs) built under a throwaway HOME,
# and run from an unrelated directory with no root argument, as a skill does.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
report="$here/skills/workai-open-project/report.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
mkdir -p "$tmp/home" "$tmp/ws" "$tmp/elsewhere"
export HOME="$tmp/home"
(cd "$tmp/ws" && . "$here/evals/_fixtures/workai.sh" && fixture_more_hubs && fixture_merged_hubs) >/dev/null 2>&1 \
  || { echo "FAIL fixture did not build"; exit 1; }
before="$(find "$tmp/ws/workai" -type f -not -path '*/.git/*' -exec shasum {} + | sort)"
cd "$tmp/elsewhere"

run() { python3 "$report" "$@" >"$tmp/out" 2>&1; echo $? >"$tmp/code"; }
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
expect() { # description exit-code [grep -E patterns that must match...]
  local d="$1" want="$2"; shift 2
  [ "$(cat "$tmp/code")" -eq "$want" ] || { fail "$d (exit $(cat "$tmp/code"), expected $want)"; return; }
  for p in "$@"; do grep -Eq -- "$p" "$tmp/out" || { fail "$d (no match for: $p)"; return; }; done
  pass "$d"
}
refute() { # description pattern: must NOT match
  if grep -Eq -- "$2" "$tmp/out"; then fail "$1"; else pass "$1"; fi
}
hubs() { grep -E '^[0-9]{2}  ' "$tmp/out" | cut -c1-2 | tr '\n' ' '; }

# --- list -------------------------------------------------------------------
run --list
expect "list: active hubs, in order" 0 "^active hubs in .*/projects \(5\):"
[ "$(hubs)" = "01 03 11 12 18 " ] && pass "list: exactly the active hubs" || fail "list: hubs were '$(hubs)'"
refute "list: no archived hubs by default" "ARCHIVED|archived hubs|Impuestos 2025|Desorden|Seguro"
refute "list: non-hub folder projects/ceramics not listed" "projects/ceramics\)"
expect "list: title and goal" 0 "^03  My Music  \(projects/03-my-music\)" \
  "goal: Collection of favourite music and the information around it\.$"
expect "list: doing card with WAITING" 0 "doing: 001 Tag the albums \[agent X\] WAITING( \(OLD: waiting [0-9]+ days\))?: question for the user"
expect "list: uncommitted work shown" 0 "git: hub 1 uncommitted"
run --list active
[ "$(hubs)" = "01 03 11 12 18 " ] && pass "list active = default" || fail "list active: '$(hubs)'"
run --list archived
expect "list archived: only archives" 0 "^archived hubs in .*/archives \(4\):" "34  Impuestos 2025 .* ARCHIVED"
[ "$(hubs)" = "02 21 23 34 " ] && pass "list archived: exactly the archived hubs" || fail "list archived: '$(hubs)'"
run --list all
[ "$(hubs)" = "01 03 11 12 18 02 21 23 34 " ] && pass "list all: both areas" || fail "list all: '$(hubs)'"
run --list bogus
expect "list: bad mode is a usage error" 2

# --- waiting on me (card 01-090) ---------------------------------------------
run --waiting
expect "waiting: the WAITING card in 03, with its question and card file" 0 \
  "^waiting on you \(1\):$" "^  03-001  Tag the albums  \(My Music\)(  waiting [0-9]+ days?.*)?$" \
  "question: question for the user, see Notes" "card: .*/projects/03-my-music/backlog/doing/001-tag-albums\.md$" \
  "^stale, no activity for 24h \(0\):$" "^blocked only by waiting cards \(0\):$"
labels="$(grep -Eo '[0-9]{2}-[0-9]{3}' "$tmp/out" | sort -u | tr '\n' ' ')"
[ "$labels" = "03-001 " ] && pass "waiting: that card and nothing else" || fail "waiting: cards were '$labels'"
run --waiting bogus extra
expect "waiting: bad arguments are a usage error" 2

# --- open by number, name, old number --------------------------------------
run 3;                expect "number 3"          0 "^hub: .*/projects/03-my-music$"
run 03;               expect "number 03"         0 "^hub: .*/projects/03-my-music$"
run "my music";       expect "name 'my music'"   0 "^hub: .*/projects/03-my-music$" "WAITING"
run my music;         expect "name unquoted"     0 "^hub: .*/projects/03-my-music$"
run "project My Music"; expect "'project ...' prefix, case" 0 "^hub: .*/projects/03-my-music$"
run mus;              expect "fragment 'mus'"    0 "^hub: .*/projects/03-my-music$"
run ceramics;            expect "name 'ceramics' (not the old-style folder)" 0 "^hub: .*/projects/11-ceramics$"
run L38;              expect "old number L38"    0 "^hub: .*/projects/11-ceramics$"
run l37;              expect "old number l37"    0 "^hub: .*/projects/03-my-music$"
run "impuestos 2026"; expect "name 'impuestos 2026'" 0 "^hub: .*/projects/18-impuestos-2026$"
run reclamacion;      expect "accents ignored, archived warned" 0 "^hub: .*/archives/02-seguro-reclamacion$" "ARCHIVED"
run "(des)orden";     expect "punctuation ignored" 0 "^hub: .*/archives/23-desorden$"

# --- repo names, aliases, merged archives (card 01-154) ---------------------
run listening-log;    expect "repo name finds its hub" 0 "^hub: .*/projects/03-my-music$"
run listening;        expect "repo name fragment finds its hub" 0 "^hub: .*/projects/03-my-music$"
run vinyl;            expect "README alias finds its hub" 0 "^hub: .*/projects/03-my-music$"
run discogs;          expect "second alias finds its hub" 0 "^hub: .*/projects/03-my-music$"
run huerto;           expect "active hub holding the repo beats the archive merged into it" 0 "^hub: .*/projects/11-ceramics$"
refute "merged archive not opened" "ARCHIVED|archives/21-huerto"
run huer;             expect "fragment: merged archive gives way too" 0 "^hub: .*/projects/11-ceramics$"
run 21;               expect "merged archive still opens by number" 0 "^hub: .*/archives/21-huerto$" "ARCHIVED"
run seguro;           expect "archive that is the only match opens, ARCHIVED" 0 "^hub: .*/archives/02-seguro-reclamacion$" "ARCHIVED"
run --list;           refute "aliases never shown in --list" "vinyl|discogs"
run --list archived;  expect "aliases line is not the goal" 0 "^21  Huerto .*ARCHIVED" "^    goal: Organise the garden plots\.$"
refute "aliases line not in --list archived" "allotment|<!--"
run allotment;        expect "alias only an archived hub has opens it, ARCHIVED" 0 "^hub: .*/archives/21-huerto$" "ARCHIVED"

# --- ambiguous: list and ask, never guess -----------------------------------
run impuestos;  expect "ambiguous name lists candidates" 3 "several hubs match" \
  "18  Impuestos 2026" "34  Impuestos 2025 .*ARCHIVED"
refute "ambiguous name opens nothing" "^hub:"
run L30;    expect "reused old number L30 is ambiguous" 3 "12  Job Change" "23  \(Des\)orden"
refute "ambiguous old number opens nothing" "^hub:"

# --- no match: fail cleanly ---------------------------------------------------
run xyzzy;  expect "no match" 2 "^no hub matches 'xyzzy'"
run L99;    expect "unknown old number" 2 "^no hub matches 'L99'"
run 7;      expect "unknown number keeps its message" 2 "^no hub numbered 07"
refute "no match opens nothing" "^hub:"


# --- status of card NNN (card 01-091) ---------------------------------------
run --card 03-001; expect "card: NN-NNN finds one card" 0 "^card: 03-001  Tag the albums$" \
  "^project: My Music \(projects/03-my-music\)$" "^status: doing, WAITING \(claimed by agent X since 2026-10-24 09:00.*\): question for the user, see Notes$" \
  "^file: .*/projects/03-my-music/backlog/doing/001-tag-albums\.md$"
run --card 01-5; expect "card: unpadded NN-N" 0 "^card: 01-005  Polish the wording$" "^status: todo, claimable$"
run --card 005; expect "card: bare id in one hub only" 0 "^card: 01-005 "
run --card 001; expect "card: bare id in two hubs lists both and asks" 3 "card 001 is in several hubs; ask which one" \
  "^  01-001  Set up the demo  \(Demo, projects/01-demo\)  \[done\]$" "^  03-001  Tag the albums  \(My Music, projects/03-my-music\)  \[doing\]$"
refute "card: ambiguous id shows no single card" "^card: "
run --card "card 3"; expect "card: 'card 3', blocked shown" 0 "^card: 01-003 " "^status: todo, blocked by 01-004$"
run --card 099; expect "card: unknown id fails cleanly" 2 "^no card 099 in any hub"
run --card 07-001; expect "card: unknown hub fails cleanly" 2 "^no card 001 in hub 07"
run --card abc; expect "card: not an id" 2 "not a card id"
(cd "$tmp/ws/workai/projects/03-my-music/notes" && python3 "$report" --card 001 >"$tmp/out" 2>&1; echo $? >"$tmp/code")
expect "card: inside a hub, the bare id means that hub" 0 "^card: 03-001  Tag the albums$"
(cd "$HOME/workai/projects/01-demo" && python3 "$report" --card 1 >"$tmp/out" 2>&1; echo $? >"$tmp/code")
expect "card: inside a hub through the ~/workai symlink" 0 "^card: 01-001  Set up the demo$" "^status: done, finished 2026-10-20$"
(cd "$HOME/workai/projects/01-demo" && python3 "$report" --card 03-002 >"$tmp/out" 2>&1; echo $? >"$tmp/code")
expect "card: NN-NNN beats the current hub" 0 "^card: 03-002  Rank the festival bill$"
(cd "$HOME/workai/projects/03-my-music" && python3 "$report" --card 004 >"$tmp/out" 2>&1; echo $? >"$tmp/code")
expect "card: not in the current hub, found elsewhere, said so" 0 "^note: no card 004 in the current hub \(03-my-music\)" "^card: 01-004 "

# --- explicit root still works ----------------------------------------------
run "my music" "$tmp/ws/workai"; expect "explicit root" 0 "^hub: $tmp/ws/workai/projects/03-my-music$"

after="$(find "$tmp/ws/workai" -type f -not -path '*/.git/*' -exec shasum {} + | sort)"
[ "$before" = "$after" ] && pass "fixture unchanged (read-only)" || { echo "FAIL fixture changed"; fails=$((fails + 1)); }

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
