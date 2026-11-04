---
name: workai-backlog
description: Rules for the card backlog in a workai project hub - picking a card, claiming it by moving the file, working in a per-card git worktree, waiting, parking a card for later, finishing, archiving, stale claims, and the global Next list. Use whenever reading, creating, claiming, working on or finishing a backlog card in ~/workai, and when the user asks to "plan next", "what should I do next" or "what next".
---

# workai backlog

Every project hub has its own `backlog/`. There is no shared backlog across
projects; card numbers are per project. Paths below are relative to the hub.

Git rules (claims on the hub's main, ids under the lock, no amend on a
shared main, what may be committed and pushed): the "Git and concurrency"
section of the workai-structure skill. They apply to every step below.

Run each shell command on its own, with absolute paths: `mv <hub>/backlog/todo/X
<hub>/backlog/doing/`, `git -C <hub> ...`, never `cd <hub> && ...` or `;`
chains. Sessions that allow only some commands refuse a chained one; one
refused command does not mean the shell is unavailable, so retry it unchained
before giving up. Reading cards needs no shell (Glob and Read).

## Layout

One file per card, `NNN-slug.md`. The folder is the status:

```
backlog/
  TEMPLATE.md
  todo/      not started
  doing/     claimed by an agent
  parked/    wanted, but deliberately not now (optional: made by the first park)
  done/      finished
  archive/   finished more than 14 days ago
```

## Card format

```markdown
---
id: 009
title: Short imperative title
repo: hub                     # or a repo name in repos/
priority: 2                   # 1 = high, 2 = normal, 3 = low
depends: []                   # card ids that must be in done/ or archive/
due:                          # optional YYYY-MM-DD: a real deadline
youtrack:                     # its group: a YouTrack issue id, e.g. H01-5
claimed_by:
worktree:
branch:
started:
waiting:
waiting_since:                # date waiting: was filled
finished:
---
## Goal
## Done when
## Notes
```

- **Done when** is a check that can fail (a command, a test, a file that must
  exist). Every card has one.
- **`due:`** is for a real, external deadline only (a court date, a tax
  date), never for a wish: `YYYY-MM-DD`. A todo or doing card due within 14
  days, or past due, comes first in `report.py --waiting` (and so "what's
  waiting on me"), in `--list` and at the top of its board column, marked
  `PAST DUE` once the date has gone. A dated item that lives only in a
  hub's notes or README is invisible there: make it a card with `due:`.
- **`youtrack:`** names the card's group, a larger YouTrack issue (local
  server, http://127.0.0.1:8645) that gathers several cards. Once one card
  of a hub has it, the hub is grouped and every open card needs one:
  `report.py` lists the ones without (`without a group`, JSON flag
  `ungrouped`). Done cards keep theirs. Hubs never grouped are not flagged,
  nor are parked cards (a parked card with a group syncs to YouTrack as
  State Parked, or Todo in a project without that value).
- The project number and the status are never written in the card: they come
  from the path (`projects/01-x/backlog/doing/009-y.md` is card `01-009`, in
  progress).

## Creating a card

1. Take the shared-file lock (two agents must not pick the same id):
   `bash <workai-migrate skill folder>/lock.sh take <your agent name>`.
2. Next id = highest id in any of `todo/ doing/ parked/ done/ archive/`, plus one.
   Three digits.
3. Copy `TEMPLATE.md` to `todo/NNN-slug.md`; fill title, repo, priority,
   depends, Goal, Done when. In a grouped hub also `youtrack:`: pick the
   existing group that fits (the hub's other cards show them); if none
   does, ask the user before creating a new YouTrack issue.
4. A card must not have a lower priority than any card that depends on it.
5. Commit the hub, then release the lock:
   `bash <workai-migrate skill folder>/lock.sh release <your agent name>`.

## Picking a card

- **Claimable** = in `todo/` and every id in `depends:` is in `done/` or
  `archive/`. Never claim a blocked card. A card in `parked/` is never
  claimable, and a card that depends on a parked card is blocked.
- Among claimable cards: first the ones listed in `~/workai/next.md` (Next),
  in its order; then lowest `priority` number, then lowest id. **Next beats
  priority on purpose**: a quick low-priority card may be ranked first. That
  is a choice, not an error; do not "fix" it.
- Pick only when asked to work on the backlog or on a specific card.

## Next (`~/workai/next.md`)

One ordered list across all projects: what the user wants done next. It is a
view and a picking order, not a status: the cards stay in `todo/`.

```
# Next: at most 5, in order
01-092  # quick win, unblocks the board
03-014  # optional one-line reason after " # "
```

- One card label (`NN-NNN`) per line; blank lines and `#` lines are ignored.
- **At most 5.** More gives a warning in `report.py` and `workai-board`;
  nothing is dropped.
- An entry whose card is no longer in `todo/` (claimed, parked, finished,
  archived, missing) is **stale**: the board hides it and `report.py --json` lists it
  under `next.stale`. Remove stale lines when you see them (claiming a card
  in Next is enough reason to delete its line) and commit the workai root,
  holding the shared-file lock (`lock.sh take`/`release`, see Creating a card).
  A blocked card stays in Next and shows as blocked: unblock it.
- Only the main agent proposes Next and the user confirms it; other agents
  only prune stale lines. The **main agent** is the session the user is
  talking to directly; an agent it spawned (a subagent, a background or
  parallel worker) is never the main agent, even when it works on cards.

**Plan next** (when the user asks to "plan next" or what to do next):

1. `python3 ~/.claude/skills/workai-open-project/report.py --json --all`
   gives every hub's todo cards, their flags and the current `next`.
2. Propose up to 5 claimable cards across all projects, in order, each with
   a one-line reason. Quick wins are welcome; say when the order goes against
   `priority:`. Mention stale or blocked entries of the current list.
3. Write `~/workai/next.md` only after the user's OK, then commit the workai
   root repo (`git -C ~/workai commit next.md`) while holding the shared-file
   lock, and push it (the root repo is private; see "Git and concurrency"
   in the workai-structure skill).

## Claiming

1. `mv backlog/todo/NNN-slug.md backlog/doing/`
   The move is atomic. If it fails, another agent took the card: pick another.
2. Fill `claimed_by` (agent and session), `started` (date and time), and for a
   repo card `worktree` and `branch`. Hub cards: `worktree: none (hub card)`,
   `branch: none`.

## Working

- A repo card never touches the main checkout in `repos/<repo>/`. Create the
  worktree from the repo:

  ```
  git -C repos/<repo> worktree add ../../worktrees/<repo>/NNN-slug -b card/NNN-slug
  ```

  and work inside `worktrees/<repo>/NNN-slug/`. Inside tmux, `workmux add`
  may be used instead; the location is the same.
- Record decisions and findings in the card's Notes as you go.
- **Waiting.** When blocked on a human, fill `waiting:` with a one-line
  summary of what is needed and `waiting_since:` with the date, and write
  the question itself, in full, in the card's Notes (options, what each
  changes, what you recommend). The card must hold everything the user needs
  to answer: never "questions in the main session" or "see chat" - a chat
  ends, the card stays. Then ask, and clear both fields once answered
  (record the answer in Notes, dated).
- **Old waiting.** `waiting:` exempts a card from STALE, not forever: a card
  waiting more than 7 days (since `waiting_since:`, else `started:`) is
  flagged OLD by `report.py --waiting` and the board. Ask again, or release
  it to `todo/` with the question kept in Notes.

## Parking

A **parked** card is wanted but deliberately not now (the user's choice, card
01-179): kept with its notes in `backlog/parked/`, never proposed by the
picker, never claimable, never stale, not counted as open work. `report.py`
and workai-board show it apart (its own section and column).

- **Park** (only when the user says so, or a card's Notes record their "not
  now"): `mv backlog/todo/NNN-slug.md backlog/parked/` (from `doing/`, first
  release the claim as in Stale claims: worktree and branch, clear the
  claim and waiting fields). `mkdir backlog/parked` the first time in a hub.
  Add a dated line to Notes: why it is parked and what would bring it back
  (a date, an event, a question). Commit the hub; drop its Next line if any
  (an entry for a parked card is stale).
- **Unpark**: `mv backlog/parked/NNN-slug.md backlog/todo/`, a dated Notes
  line, commit. It is then an ordinary todo card; claim it as usual.
- A card that `depends:` on a parked card stays blocked until the parked
  card is unparked and finished. If that is wrong, ask the user whether to
  unpark the blocker or drop the dependency.
- A real deadline (`due:`) does not fit a parked card: unpark it, or ask.
- Parking replaces the per-hub workarounds (a `notes/parked.md` list, a
  todo card at priority 3 with "not now" in its Notes): from now on a
  parked item is a card in `parked/`. Entries that already live in a
  hub's `notes/parked.md` stay there until someone picks one up; it then
  becomes a card (parked or todo), and its line is removed.

## Finishing

Repo card:

1. Run the Done-when check in the worktree. If it fails, the card is not done.
2. Merge from the main checkout:
   `git -C repos/<repo> merge --ff-only card/NNN-slug`
   (rebase the branch on main first if needed).
3. `git -C repos/<repo> worktree remove ../../worktrees/<repo>/NNN-slug` and
   `git -C repos/<repo> branch -d card/NNN-slug`.

**`workai-playbooks` only: through a pull request** (AI reviewer pilot, card
01-084; every other repo keeps the local merge above until the pilot is
judged). Instead of step 2:

1. Rebase the branch on the latest main, run the full suite and
   `scripts/check-skills.py`, then push the card branch (never main):
   `git -C <worktree> push -u origin card/NNN-slug`.
2. `gh pr create --repo sbartek/workai-playbooks --head card/NNN-slug
   --base main --title "NNN: <card title>" --body "<what and why; card 01-NNN>"`.
3. Wait for the checks (`gh pr checks <n> --watch`). The `AI review`
   workflow keeps one comment on the PR and rewrites it on every push, or
   skips green with a notice while the `OPENCODE_API_KEY` secret is
   missing. Judge each finding in the card's Notes (useful / wrong /
   noise); fix what is right with new commits, and wait for the new
   review of the new head before merging.
4. Merge keeping main linear: `gh pr merge <n> --rebase --delete-branch`
   (deletes the remote branch), or, if main moved, rebase again, rerun the
   tests, force-push the card branch only (`--force-with-lease`), wait for
   the new AI review of the new head (judge it as in step 3), and merge
   once checks are green. Then `git -C repos/workai-playbooks pull
   --ff-only` in the main checkout and finish with the Repo card cleanup:
   `git -C repos/workai-playbooks worktree remove
   ../../worktrees/workai-playbooks/NNN-slug`, then delete the local branch
   if it still exists. A rebase merge gives the commits new ids, so `branch
   -d` refuses it: once
   `gh pr view <n> --repo sbartek/workai-playbooks --json state` says
   `MERGED`, use `git -C repos/workai-playbooks branch -D card/NNN-slug`.

Never merge someone else's PR; never push main directly for a card.

Every card, at the end:

0. Its own Done-when check has run and passed. A check that cannot run yet
   (an eval blocked elsewhere, a hand check by the user) keeps the card in
   `doing/` with `waiting:` filled; moving the check to another card ("owed
   in 072") does not close this one. A hand check counts once the user's
   confirmation is a dated line in Notes.
1. Write what was done or decided into Notes, including anything left over.
   Leftover work becomes a new card, not a silent gap.
2. Set `finished:` to the date; move the card to `done/`.
3. Commit the hub.
4. Push what the "Git and concurrency" section of the workai-structure
   skill allows: the private hub and private outcome repos, through the
   scanning pre-push hook. Ask first for public repos, pushes that deploy,
   and local-only hubs.

## Archiving

Cards in `done/` whose `finished:` is more than 14 days old move to
`archive/`. Any agent working in the hub may move them and commit. File dates
are never used: git checkouts reset them.

## Stale claims

A card in `doing/` is **stale** after 24 hours without activity, unless
`waiting:` is filled. A parked card is never stale. Activity = the newest of: last commit on its branch,
last file change in its worktree, last edit of the card (hub cards have only
the last).

Stale is a flag, never an automatic cleanup. Release a stale card only when
asked:

1. Worktree has uncommitted changes or commits not on main: keep the branch,
   add "previous attempt: branch `card/NNN-slug`" to Notes, clear the claim
   fields, move the card back to `todo/`.
2. Worktree is clean with nothing new: remove the worktree and the branch,
   clear the claim fields, move the card back to `todo/`.
