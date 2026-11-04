---
name: workai-open-project
description: Open one workai project by its number, old L number or name - when the user says "work on project 1", "open project 03", "work on project my music", "open ceramics" or "project L38", find that hub in ~/workai, read its README and CLAUDE.md, and report its state and backlog. Also answers "status of card 042" or "what happened to 01-042" for one card in any hub. Use for any request to start or resume work on one workai project; to list projects use workai-list-projects.
---

# Open a workai project

"project N" always means the hub numbered N (`01`, `02`, ...), never an old
project number from `~/workai/CLAUDE.md` (see the workai-structure skill). An
old number is written with its `L` ("L38") and is looked up through the hub's
"old number L38" note. Anything else is a name: a word or fragment of the
hub's folder name, README title, a folder name in its `repos/`, or a word in
its README `<!-- aliases: word, word -->` line ("my music", "impuestos 2026",
"listening-log" for `03-my-music` with the repo `listening-log`), case and accents ignored.
When an archived hub titled "(merged into NN — ...)" and hub NN both match,
hub NN opens; an archived hub that is the only match still opens, ARCHIVED.

## Steps

1. Run the report script that sits next to this file with what the user
   called the project (number, `L` number or name, quoted):

   ```
   python3 <this skill's folder>/report.py "my music"
   ```

   Run it alone, exactly like that: nothing chained (`;`, `&&`, `echo $?`).
   A non-zero exit code shows in the result anyway, and sessions that allow
   only `python3` refuse a chained command. Likewise run git as
   `git -C <path> ...`, never `cd <path> && git ...`.

   - Exit 0: the first line is `hub: <path>`; go on.
   - Exit 3, "several hubs match": show the user the candidates it printed
     and ask which one (see "Asking" below). Do not pick one yourself, not
     even the active one.
   - Exit 2, "no hub matches" / "no hub numbered": tell the user and stop;
     do not guess a similar project. `report.py --list all` shows what
     exists, if they want to look.
2. From now on use absolute paths under that hub path: `<hub>/README.md`,
   `git -C <hub> ...`. Do not `cd` into it, and never `cd <hub> && ...`:
   some agents' shells set the folder per call, and sessions that
   allow only some commands refuse a chained one.
3. Read the hub's `README.md` and `CLAUDE.md` (an agent started elsewhere does
   not load them by itself) and follow `CLAUDE.md` from now on.
4. Report to the user, briefly:
   - project number, name and one-line goal (from `README.md`);
   - if the report says ARCHIVED, say so first;
   - structure version, and whether it is behind the current major;
   - **doing**: each card with who holds it, its worktree, and any WAITING or
     STALE flag;
   - **claimable**: the top cards in picking order (Next from
     `~/workai/next.md` first, marked `[next]`, then priority, then id), and
     any blocked or stale Next line the report prints;
   - how many cards are blocked;
   - **parked**: the cards in `backlog/parked/` (wanted, not now), in one
     line; never offer them as work unless the user asks to unpark one;
   - what was finished recently;
   - **git**: anything uncommitted or unpushed in the hub or its repos, and
     leftover worktrees.
5. Stop and ask what to work on (see "Asking" below). Do not claim a card
   until the user chooses (claiming follows the workai-backlog skill).

## Asking

When a step says "ask", use the agent's way of asking the user. If there is
none (a headless run, no question tool, or the tool fails), end your answer
with the question as plain text and stop: never answer it yourself.

## Status of one card

For "status of card 042", "what happened to 01-042", "where is card 7",
run alone, without opening the project:

```
python3 <this skill's folder>/report.py --card 042
```

- `NN-NNN` is exact. A bare id means the hub the current directory is in
  (if that hub has it); otherwise every hub, active and archived, is
  searched.
- Exit 0: one card: report its project, status line (todo/claimable or
  blocked, doing with holder, WAITING with the question, STALE, parked,
  done with date), due date, and the last Notes items it prints. Offer to open the
  card file for more.
- Exit 3, "in several hubs": show the list (label, title, project, status)
  and ask which one (see "Asking"). Never pick one.
- Exit 2: no such card; say so. Read-only: change nothing.

## Report script

[report.py](report.py) reads the backlog and git state; it never changes
anything. Card status comes from the folder, the project number from the hub's
folder name. `report.py --list [active|archived|all]` lists hubs and
`report.py --waiting` lists every card waiting on the user across the active
hubs, then stale cards, then cards blocked only by waiting ones (both used by
the workai-list-projects skill).

`report.py --index` prints the compact workai index (header plus one line
per hub: number, title, old number, scrubbed goal, path, repos; a hub's
README can set its line with `<!-- index: ... -->`). Since 2026-10-25
(card 01-106) `~/workai/CLAUDE.md` is exactly this output, never edited by
hand. [regen-index.sh](regen-index.sh) `[MESSAGE]` rewrites it and commits
it with `~/workai/.gitignore` (those two paths only), under the shared-file
lock: it uses the lock when this session (or `WORKAI_LOCK_OWNER`) already
holds it, else takes and releases it. new-project.sh, migrate.sh and
archive.sh call it; run it after changing a hub's title, goal or index line.

`report.py --json --all` prints every card of every hub in `projects/` as JSON
(fields, body, dependents and the flags claimable, blocked, stale, waiting,
overdue) and `next` (the `~/workai/next.md` order, the todo cards it shows,
stale ids, warnings; each card's `next` place); `--archives` adds archived
hubs, `--git` adds git state, and a number instead of `--all` gives one hub. Tools such as `workai-board` read it,
so the backlog rules stay in this one script.
