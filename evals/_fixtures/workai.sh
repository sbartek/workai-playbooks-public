#!/usr/bin/env bash
# Build a small fake ~/workai inside the eval workspace and point $HOME/workai
# at it, so the skills run unchanged and graders can read the result as
# workspace files (workai/...). Sourced by each case's scaffold.sh.
set -eu
ws="$(pwd)"
mkdir -p "$ws/workai/projects" "$ws/workai/archives" "$ws/workai/projects/ceramics"
ln -sfn "$ws/workai" "$HOME/workai"
printf '# Projects\n\n## 01 — Demo\nDemo hub.\n\n## L38 — Ceramics\nOld-style project.\n' >"$ws/workai/CLAUDE.md"
printf 'projects/01-demo/\n' >"$ws/workai/.gitignore"

hub="$ws/workai/projects/01-demo"
mkdir -p "$hub"/backlog/{todo,doing,done,archive} "$hub"/notes "$hub"/repos "$hub"/worktrees
printf '# 01 — Demo\n\nDemo hub for evals. Goal: test the workai skills.\n' >"$hub/README.md"
printf '# 01 — Demo (hub)\n\n- Follow the workai-backlog skill for cards.\n' >"$hub/CLAUDE.md"
printf '.DS_Store\nrepos/\nworktrees/\n' >"$hub/.gitignore"
echo 1.0.0 >"$hub/STRUCTURE"
card() { # folder id slug priority depends finished title
  cat >"$hub/backlog/$1/$2-$3.md" <<CARD
---
id: $2
title: $7
repo: hub
priority: $4
depends: [$5]
claimed_by:
worktree:
branch:
started:
waiting:
finished: $6
---
## Goal
$7.

## Done when
A file notes/$3.md exists.

## Notes
CARD
}
card done 001 setup 1 "" 2026-10-20 "Set up the demo"
card todo 002 write-intro 1 "001" "" "Write the intro"
card todo 003 write-summary 1 "004" "" "Write the summary"
card todo 004 collect-data 2 "" "" "Collect the data"
card todo 005 polish 3 "" "" "Polish the wording"
git -C "$hub" init -q
git -C "$hub" -c user.name=eval -c user.email=eval@example.com add -A
git -C "$hub" -c user.name=eval -c user.email=eval@example.com commit -q -m "Fixture"

# More hubs, for the list and open-by-name cases only (other cases rely on 01
# being the only hub). Call fixture_more_hubs after sourcing this file. Gives
# active and archived hubs, a shared word ("impuestos"), an accent ("reclamación"),
# old numbers including a reused one (L30 on 12 and 23), a WAITING card and an
# uncommitted file.
fixture_more_hubs() {
  local area num slug title goal old h
  while IFS='|' read -r area num slug title goal old; do
    h="$ws/workai/$area/$num-$slug"
    mkdir -p "$h"/backlog/{todo,doing,done,archive} "$h"/notes "$h"/repos "$h"/worktrees
    printf '# %s — %s\n\nProject hub. Created 2026-10-24.\n\n## Goal\n\n%s\n\n## Layout\n\n- Migrated 2026-10-24 (was `projects/%s`, old number\n  %s).\n' \
      "$num" "$title" "$goal" "$slug" "$old" >"$h/README.md"
    printf '# %s — %s (hub)\n\n- Follow the workai-backlog skill for cards.\n' "$num" "$title" >"$h/CLAUDE.md"
    echo 1.0.0 >"$h/STRUCTURE"
    printf '\n## %s — %s (was %s)\n%s\n' "$num" "$title" "$old" "$goal" >>"$ws/workai/CLAUDE.md"
  done <<'HUBS'
projects|03|my-music|My Music|Collection of favourite music and the information around it. Notes plus a listening timeline.|L37
projects|11|ceramics|Ceramics|Learning ceramics: wheel throwing, glazes and firing at the shared kiln.|L38
projects|12|job-change|Job Change|Move to a new job: notice period, handover and the first month.|L30
projects|18|impuestos-2026|Impuestos 2026|Prepare the yearly tax return for 2026.|L35
archives|02|seguro-reclamacion|Seguro reclamación|Contest the automatic contract renewal and its early-exit penalty.|L1
archives|23|desorden|(Des)orden|Spanish-language decluttering app, analysis phase.|L30
archives|34|impuestos-2025|Impuestos 2025|The yearly tax return for 2025.|L19
HUBS
  h="$ws/workai/projects/03-my-music"
  cat >"$h/backlog/doing/001-tag-albums.md" <<'CARD'
---
id: 001
title: Tag the albums
repo: hub
priority: 1
depends: []
claimed_by: agent X
worktree: none (hub card)
branch: none
started: 2026-10-24 09:00
waiting: question for the user, see Notes
finished:
---
## Goal
Tag the albums.

## Done when
notes/tags.md exists.

## Notes
CARD
  cat >"$h/backlog/todo/002-rank-festival.md" <<'CARD'
---
id: 002
title: Rank the festival bill
repo: hub
priority: 2
depends: []
claimed_by:
worktree:
branch:
started:
waiting:
finished:
---
## Goal
Rank the festival bill.

## Done when
notes/ranking.md exists.

## Notes
CARD
  git -C "$h" init -q
  git -C "$h" -c user.name=eval -c user.email=eval@example.com add -A
  git -C "$h" -c user.name=eval -c user.email=eval@example.com commit -q -m "Fixture"
  echo "draft" >"$h/notes/draft.md"
}

# A merge, repo names and aliases, for the open-by-name cases of card 01-154
# (call after fixture_more_hubs). Hub 11 holds the repo `huerto` taken over
# from archived hub 21 "(merged into 11 — Ceramics)", whose README has no Goal
# heading and an aliases line before its first paragraph; 03 has the repo
# `listening-log` and the README line `<!-- aliases: vinyl, discogs -->`.
fixture_merged_hubs() {
  local r h="$ws/workai/archives/21-huerto"
  mkdir -p "$h"/backlog/{todo,doing,done,archive} "$h"/notes "$h"/repos
  printf '# 21 — Huerto (merged into 11 — Ceramics)\n\n<!-- aliases: allotment -->\n\nOrganise the garden plots.\n' >"$h/README.md"
  echo 1.0.0 >"$h/STRUCTURE"
  for r in projects/11-ceramics/repos/huerto projects/03-my-music/repos/listening-log; do
    git -C "$ws/workai" init -q "$r"
    echo "# ${r##*/}" >"$ws/workai/$r/README.md"
    git -C "$ws/workai/$r" -c user.name=eval -c user.email=eval@example.com add -A
    git -C "$ws/workai/$r" -c user.name=eval -c user.email=eval@example.com commit -q -m "Fixture"
  done
  h="$ws/workai/projects/03-my-music"
  printf '<!-- aliases: vinyl, discogs -->\n' >>"$h/README.md"
  printf 'repos/\n' >>"$h/.gitignore"
  git -C "$h" -c user.name=eval -c user.email=eval@example.com add README.md .gitignore
  git -C "$h" -c user.name=eval -c user.email=eval@example.com commit -q -m "Aliases"
}
