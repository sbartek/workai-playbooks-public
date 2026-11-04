---
name: workai-archive-project
description: Archive a finished workai project - move its numbered hub from ~/workai/projects to ~/workai/archives (or restore it), after checking nothing is in progress, and update everything that pointed at the old path. Use when the user asks to archive, close, shelve or restore a workai project.
---

# Archive a workai project

Archiving is a move, so it breaks every reference to the old path unless each
one is updated. Same discipline as the workai-migrate skill: plan, confirm,
move, update, verify. Only when the user asks, one project at a time.

The number stays with the project; numbers are never reused, so archived
projects keep theirs and "project N" still finds them.

## Archive

1. An old-style project (no number) is migrated to a hub first with the
   workai-migrate skill, then archived.
2. **Plan.** Run the dry run next to this file:

   ```
   bash <this skill's folder>/archive.sh --dry-run NN
   ```

   It refuses while cards are in `backlog/doing/` or a repo has linked
   worktrees (their git metadata holds absolute paths), warns about
   uncommitted or unpushed work, and lists every reference to the hub's path.
   It uses `find-refs.py` from the workai-migrate skill, so both must be
   installed.
3. **Show the user the plan and the references; wait for a yes.** Ask separately
   whether to archive the GitHub repos as well (`gh repo archive`), since that
   changes something public-facing; default is to leave them. With no way
   to ask (headless), end with both questions as text and stop.
4. **Move** (hold the shared-file lock until step 5 is done: `bash
   <workai-migrate skill folder>/lock.sh take|release <your agent name>`,
   each as its own command). Run it without `--dry-run`. It moves the hub to `archives/`,
   updates the hub's line in `~/workai/.gitignore`, and regenerates
   `~/workai/CLAUDE.md` with `report.py --index` (via `regen-index.sh` of
   the workai-open-project skill; the hub moves to the Archived list),
   committing those two files in `~/workai`. It never edits a `## NN`
   section: the index is generated. If it says the index was not
   regenerated (exit 1), fix the cause and run `regen-index.sh`.
5. **Update every reference**: `~/workai/CLAUDE.md` is already done (to
   change the hub's index line, edit its README goal or `<!-- index: ... -->`
   line and run `regen-index.sh` again, never the index itself); fix memory
   notes and mark them archived; unload launchd jobs (`launchctl unload`) and
   remove or disable cron entries the project no longer needs, rather than
   pointing them at the archive; re-run `install.sh` or remove symlinks that
   pointed into the hub.
6. **Verify**: `find-refs.py projects/NN-name` reports only history you chose
   to keep; `launchctl list` no longer shows its jobs; the
   workai-open-project report for NN says ARCHIVED.

## Restore

`archive.sh --restore NN` moves it back from `archives/` to `projects/` and
regenerates the index the same way; then the same reference update and
verification, in reverse.

## Notes

`WORKAI_ROOT` overrides `~/workai` (tests).
