---
name: workai-new-project
description: Create a new numbered project hub in ~/workai (projects/NN-name with backlog, notes, repos, worktrees, STRUCTURE, its own git repo, listed in workai's generated index CLAUDE.md), and add outcome repos to a hub. Use when the user asks to start, create or set up a new workai project, or to add a repo to a project.
---

# Create a workai project

The layout and numbering rules are in the workai-structure skill. This skill
creates them; it never moves or renumbers existing projects (that is
migration, a separate job).

## New project

1. Agree with the user on a short `name` (lowercase kebab-case, e.g.
   `home-gym`) and a title (e.g. `Home Gym`). Ask; do not invent them (with
   no way to ask, end with the question as text and stop).
2. Take the shared-file lock (the number and the workai files must not race
   another agent) with `bash <workai-migrate skill folder>/lock.sh take
   <your agent name>`, as its own command (see the workai-migrate skill), then
   run the script next to this file:

   ```
   bash <this skill's folder>/new-project.sh NAME "Title"
   ```

   It picks the next number (highest `NN-` in `projects/` and `archives/`,
   plus one), creates `projects/NN-name/` with `README.md`, `CLAUDE.md`,
   `STRUCTURE`, `backlog/` (with `TEMPLATE.md`), `notes/`, `repos/`,
   `worktrees/`, makes it a git repo on branch `main` with a first commit, adds it to
   `~/workai/.gitignore`, then regenerates the whole `~/workai/CLAUDE.md`
   with `report.py --index` (via `regen-index.sh` of the workai-open-project
   skill) and commits those two files in `~/workai`. It prints the hub path.
   It never writes a `## NN` section: the index is generated, never edited
   by hand.
3. Fill in the goal in the hub's `README.md`, with the user's words (its first
   Goal sentence becomes the index line; add an `<!-- index: ... -->` line
   when that sentence is not right for the always-loaded index), commit the
   hub, then regenerate the index:
   `bash <workai-open-project skill folder>/regen-index.sh "Index: NN goal"`.
4. Create the hub's private GitHub repo (the user's default; no need to ask)
   with `bash <this skill's folder>/push-hub.sh <hub> sbartek/NN-name` and
   put the URL in the hub README. It first scans the whole
   history for secrets and identity documents (scan.py; gitleaks too when
   installed) and stops on a hit: then push nothing, tell the user which files
   (never their contents) and ask. Never `gh repo create` by hand, never
   `--no-verify`, never a public repo or a visibility change without asking.
5. Release the lock: `bash <workai-migrate skill folder>/lock.sh release
   <your agent name>`.
6. `~/workai` itself is a git repo that other sessions also change: commit
   in it only what the "Git and concurrency" section of the workai-structure
   skill allows (under the lock), and push it as that section allows.
   `regen-index.sh` already committed the index and `.gitignore`.
   If it reported "index was not regenerated" (the script exits 1, the hub
   is kept), fix the cause and run `regen-index.sh` again.

## Add an outcome repo

```
bash <this skill's folder>/add-repo.sh <hub path> NAME [GIT-URL]
```

Creates `repos/NAME` (empty repo on branch `main`, or a clone of GIT-URL), the matching
`worktrees/NAME/` folder, and a local `.workmux.yaml` excluded from the repo's
history so workmux puts worktrees in the hub. Creating its GitHub repo also
needs the user's yes.

## Files

- [new-project.sh](new-project.sh) and [add-repo.sh](add-repo.sh)
- [push-hub.sh](push-hub.sh): scan, then push to a private repo.
  [scan.py](scan.py) is the scanner; [install-scan-hook.sh](install-scan-hook.sh)
  puts it in a repo's pre-push hook (new-project.sh does this for every hub).
  False positives go in `.workai-scan-allow` at the repo root
  (`path-glob [rule]` per line), with the user's OK.
- [template/](template) holds the hub files the script copies.
- `WORKAI_ROOT` overrides `~/workai`, for tests only.
