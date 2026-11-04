#!/usr/bin/env bash
# Turn an old-style workai project (structure 0) into a numbered hub.
#
#   migrate.sh [--dry-run] NAME "Title" ITEM [ITEM...]
#
# NAME is the hub's name (kebab-case); ITEMs are what belongs to the project
# under projects/: a git repo folder (moves to the hub's repos/), a plain
# folder or a file (moves to the hub's notes/<item>). Example:
#   migrate.sh ceramics "Ceramics" ceramics
#   migrate.sh jubilacion "Jubilación" jubilacion.md jubilacion-pension-model.py
#
# Moves files, then regenerates the workai index (CLAUDE.md, report.py
# --index) and commits it with .gitignore. It does NOT rewrite other
# references (launchd, memory notes, symlinks): the plan lists them and the
# agent updates each one with the user's confirmation. If a run fails half-way, fix the cause and run
# the same command again: it resumes. WORKAI_ROOT overrides ~/workai (tests).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="${WORKAI_ROOT:-$HOME/workai}"
dry=0; [ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
name="${1:-}"; title="${2:-}"
[ $# -ge 3 ] || { sed -n '4,12p' "$0" | sed 's/^# *//'; exit 2; }
shift 2

# Validate everything before printing a plan or touching anything.
echo "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || { echo "name must be lowercase kebab-case: $name"; exit 2; }
[ -n "$title" ] || { echo "title must not be empty"; exit 2; }
dup="$(printf '%s\n' "$@" | sort | uniq -d | head -1)"
[ -z "$dup" ] || { echo "item given twice: $dup"; exit 2; }

# A run that failed half-way leaves its hub with a marker in .git/; re-running
# the same command resumes it: items already moved are skipped.
hub=""; resume=0
for d in "$root"/projects/[0-9][0-9]-"$name" "$root"/archives/[0-9][0-9]-"$name"; do
  [ -e "$d" ] || continue
  if [ -f "$d/.git/workai-migrating" ] && [ "${d#"$root"/projects/}" != "$d" ]; then hub="$d"; resume=1
  else echo "a hub named $name already exists: $d"; exit 1; fi
done
dest_of() { if [ -d "$root/projects/$1/.git" ] || [ -d "$hub/repos/$1/.git" ]; then echo "repos/$1"; else echo "notes/$1"; fi; }

for item in "$@"; do
  case "$item" in */*|.*|"") echo "item must be a plain name under projects/: $item"; exit 2 ;; esac
  case "$item" in [0-9][0-9]-*) echo "already a hub: $item"; exit 2 ;; esac
  if [ ! -e "$root/projects/$item" ]; then
    [ "$resume" = 1 ] && [ -e "$hub/$(dest_of "$item")" ] && continue
    echo "not found: projects/$item"; exit 2
  fi
  [ "$resume" = 1 ] && [ -e "$hub/$(dest_of "$item")" ] && { echo "both projects/$item and $(basename "$hub")/$(dest_of "$item") exist; resolve by hand"; exit 1; }
done

[ "$resume" = 1 ] && echo "Resuming the unfinished migration into $(basename "$hub")"
echo "Plan for hub '$name' ($title):"
for item in "$@"; do
  src="$root/projects/$item"
  if [ ! -e "$src" ]; then echo "  projects/$item  ->  $(dest_of "$item")  (already moved)"; continue; fi
  if [ -d "$src/.git" ]; then echo "  projects/$item  ->  repos/$item  (git repo)"
  else echo "  projects/$item  ->  notes/$item"; fi
  if [ -d "$src/.git" ]; then
    # A failing git is a STOP, never "clean".
    st="$(git -C "$src" status --porcelain 2>/dev/null)" || { echo "  STOP: git failed on $item"; exit 1; }
    wl="$(git -C "$src" worktree list 2>/dev/null)" || { echo "  STOP: git failed on $item"; exit 1; }
    dirty="$(printf '%s' "$st" | grep -c . || true)"
    wts="$(printf '%s\n' "$wl" | grep -c .)"
    [ "$dirty" = 0 ] || echo "  WARNING: $item has $dirty uncommitted change(s)"
    [ "$wts" = 1 ] || { echo "  STOP: $item has $((wts - 1)) linked worktree(s); finish or remove them first"; exit 1; }
    if [ -e "$src/.workmux.yaml" ]; then
      if git -C "$src" ls-files --error-unmatch .workmux.yaml >/dev/null 2>&1; then
        echo "  NOTE: $item tracks its own .workmux.yaml; it is left alone (check its worktree_dir)"
      else echo "  NOTE: $item already has a local .workmux.yaml; it is left alone"; fi
    fi
  fi
done
echo "References that will need updating:"
refs=(); for item in "$@"; do refs+=("projects/$item"); done
python3 "$here/find-refs.py" "${refs[@]}" | sed 's/^/  /' || true
[ "$dry" = 1 ] && { echo "(dry run: nothing moved)"; exit 0; }

if [ "$resume" = 0 ]; then
  hub="$(NO_REGISTER=1 bash "$here/../workai-new-project/new-project.sh" "$name" "$title" | tail -1)"
  [ -d "$hub" ] || { echo "hub was not created"; exit 1; }
  echo "$*" >"$hub/.git/workai-migrating"
fi
for item in "$@"; do
  src="$root/projects/$item"
  [ -e "$src" ] || continue   # moved by an earlier, interrupted run
  if [ -d "$src/.git" ]; then
    mkdir -p "$hub/worktrees/$item"
    if [ ! -e "$src/.workmux.yaml" ]; then
      printf '# Local only (excluded via .git/info/exclude): worktrees go in the hub.\nworktree_dir: ../../worktrees/{project}\n' >"$src/.workmux.yaml"
      grep -qxF '.workmux.yaml' "$src/.git/info/exclude" 2>/dev/null \
        || echo ".workmux.yaml" >>"$src/.git/info/exclude"
    fi
    mv "$src" "$hub/repos/$item"
  else
    rm -f "$hub/notes/.gitkeep"
    mv "$src" "$hub/notes/$item"
  fi
done
git -C "$hub" add -A
# repos/ is ignored by the hub, so a repo-only migration has nothing to commit.
git -C "$hub" diff --cached --quiet || git -C "$hub" commit -q -m "Migrate $* into hub $(basename "$hub")"

# workai .gitignore: the old per-item lines go, the hub's line comes in.
# Fixed strings, not regex: a "." in an item name must not match other lines.
gi="$root/.gitignore"; touch "$gi"
for item in "$@"; do
  grep -vxF -e "projects/$item/" -e "projects/$item" "$gi" >"$gi.tmp" || true; mv "$gi.tmp" "$gi"
done
grep -qxF "projects/$(basename "$hub")/" "$gi" || echo "projects/$(basename "$hub")/" >>"$gi"
rm -f "$hub/.git/workai-migrating"

echo "Migrated into $hub"
# The index is generated, never hand-edited: the old `## Lnn` section goes,
# the hub's line comes from its README (goal, old Lnn, `<!-- index: -->`).
indexed=1
bash "$here/../workai-open-project/regen-index.sh" "Migrate $* into hub $(basename "$hub")" || indexed=0
# Moved-in repos get the pre-push scan too (the hub has it from new-project.sh).
for r in "$hub"/repos/*/; do
  [ -e "$r.git" ] || continue
  bash "$here/../workai-new-project/install-scan-hook.sh" "${r%/}" >/dev/null \
    || echo "NOTE: pre-push scan hook not installed in ${r%/} (it has another pre-push hook)"
done
# Scan before anyone pushes it (the hub has the pre-push hook from new-project.sh).
if python3 "$here/../workai-new-project/scan.py" "$hub" >"$hub/.git/workai-scan.txt" 2>&1; then
  echo "Scan: clean"
else
  echo "Scan: HITS, do not push until fixed (push-hub.sh and the pre-push hook will refuse):"
  sed 's/^/  /' "$hub/.git/workai-scan.txt"
fi
[ "$indexed" = 1 ] || echo "WARNING: the workai index was NOT regenerated: run regen-index.sh (workai-open-project)"
echo "Next: update every reference listed above, fill the hub README (goal, old Lnn),"
echo "regenerate the index again (regen-index.sh), then re-run:"
echo "  python3 $here/find-refs.py ${refs[*]}"
echo "$hub"
[ "$indexed" = 1 ]
