---
name: workai-migrate
description: Migrate a workai project to the current structure - turn an old-style project (a plain repo, folder or .md plan in ~/workai/projects, structure 0) into a numbered hub, or upgrade a hub to a newer structure major - finding and updating everything that points at the old path. Use when the user asks to migrate, convert or upgrade a workai project.
---

# Migrate a workai project

Layout and numbering are in the workai-structure skill. Migrating moves files,
and every reference to the old path breaks silently unless it is updated, so
the work is: plan, confirm, move, update references, verify.

Only when the user asks, one project at a time.

## Old-style project to hub

1. **Choose the items.** A project can be several things under `projects/`:
   a git repo folder, a plain folder, a `.md` plan, a stray script or archive
   (`jubilacion.md` + `jubilacion-pension-model.py`). Its notes (saved in
   the hubs from the old hand-kept index by card 01-106) or its own README
   usually name them. Agree the hub
   name (kebab-case) and title with the user.
2. **Plan.** Run the dry run next to this file:

   ```
   bash <this skill's folder>/migrate.sh --dry-run NAME "Title" ITEM [ITEM...]
   ```

   It shows where each item goes (git repo → `repos/<item>`, anything else →
   `notes/<item>`), warns about uncommitted changes, refuses repos with linked
   worktrees, and lists every reference to the old paths (via
   [find-refs.py](find-refs.py)).
3. **Show the user the plan and the reference list; wait for a yes.** Point out
   anything risky: launchd jobs, crontab entries, symlinks, unpushed work.
4. **Move** (hold the shared-file lock from here to the end of step 6). Run
   the same command without `--dry-run`. It creates the hub
   (next number, without registering it), moves the items, commits the hub,
   swaps the item lines in `~/workai/.gitignore` for the hub's line, and
   regenerates `~/workai/CLAUDE.md` with `report.py --index` (via
   `regen-index.sh`), committing those two files in `~/workai`. It never
   writes or converts a `## NN` / `## Lnn` section: the index is generated.
   A repo's own tracked `.workmux.yaml` is left alone (reported). If the
   move fails half-way, fix the cause and run the same command again: it
   resumes the unfinished hub instead of making a second one.
5. **Update every reference** from the list:
   - `~/workai/CLAUDE.md` is generated: never edit it. Its line for the hub
     comes from the hub README (title, goal, old `Lnn`); after filling the
     README (5b), regenerate it with
     `bash <workai-open-project skill folder>/regen-index.sh "Index: NN"`.
   - memory notes: fix paths; keep the history (e.g. "was L38").
   - launchd plists: fix paths, then `launchctl unload` / `load` the job.
   - crontab: edit the entry (`crontab -e` content via `crontab -l`).
   - skill symlinks: re-run that repo's `install.sh` from its new place.
   - files in other projects: fix the path, commit in that repo.
   - the moved repo's own README or docs: fix self-references.
5b. **Fill the hub.**
   - A repo moves into `repos/` whole, history intact, even when it mixes
     plans with outcome; do not split files out of it during migration.
   - Copy the goal and current status from the project's own README and
     notes into the hub `README.md`, with a Layout section saying what moved
     where and the old `Lnn` (the index shows it as "was Lnn"). Add an
     `<!-- index: ... -->` line when the first Goal sentence is not right
     for the always-loaded index (names, identifiers).
   - If the repo keeps plan or to-do files (`PLAN.md`, `TODO.md`,
     `queue.md`, ...), add card 001 in the hub: turn them into cards.
   - Create the hub's private GitHub repo (the default, no need to ask):
     `bash <workai-new-project skill folder>/push-hub.sh <hub> sbartek/NN-name`,
     and put the URL in the hub README. Never public. It scans the history first
     and stops on secrets or identity documents (migrate.sh already printed
     the scan result): on a hit push nothing and ask the user.
6. **Verify, do not assume.**
   - `python3 find-refs.py projects/ITEM` must report only history you chose
     to keep (say which).
   - Each launchd job: `launchctl list | grep <label>` shows it loaded, and
     its next run (or a manual `launchctl kickstart`) succeeds; check its log.
   - The repo still has its remote and nothing was lost:
     `git -C repos/ITEM status` and `git -C repos/ITEM log -1`.
   - `python3 <workai-open-project>/report.py NN` works for the new hub.
7. Tell the user what moved, what was updated, and what was verified how.
   `~/workai` itself: commit only what the "Git and concurrency" section of
   the workai-structure skill allows, under the lock, and push it as that
   section allows.

## Shared-file lock (several agents at once)

Creating a hub number or a card id, and editing shared files
(`~/workai/CLAUDE.md`, `~/workai/.gitignore`, `~/workai/next.md` and any
other workai-root commit, memory notes, launchd plists, the 01 hub's review
table) must not overlap between agents. Take the lock first, release it after,
with the script next to this file, each as its own command (nothing chained):

```
bash <this skill's folder>/lock.sh take <your agent name>      # waits up to 10 min
bash <this skill's folder>/lock.sh release <your agent name>
bash <this skill's folder>/lock.sh status
```

The lock is the directory `~/workai/.workai.lock` with an `owner` file that
records the owner (spaces allowed), since, pid, host and session. `take`
breaks a lock by itself when its owner process is gone on this host, or when
a crashed take left no owner file for over a minute, and says so on stderr.
Otherwise, if `take` times out it names the holder, its age and pid; a lock
from another host or an old-format owner whose holder is really gone may be
removed by hand (`rm -r ~/workai/.workai.lock`); say so in your notes.

## Hub to a newer structure major

1. Read the hub's `STRUCTURE` and the current `VERSION` of `workai-playbooks`.
2. Apply, in order, the **Migration** sections of `CHANGELOG.md` for every
   major above the hub's, showing the user the steps first.
3. Write the new version to `STRUCTURE`; commit the hub.

## Notes

- `WORKAI_ROOT` overrides `~/workai` (tests). `find-refs.py` has more
  overrides, listed in its header.
- Archiving a project (moving a hub to `archives/`) is a separate skill.
