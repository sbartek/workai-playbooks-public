#!/usr/bin/env bash
# Move a numbered hub from projects/ to archives/ (or back with --restore).
#
#   archive.sh [--dry-run] NN             e.g. archive.sh 7
#   archive.sh [--dry-run] --restore NN
#
# Refuses while the hub has cards in doing/ or live worktrees (the hub's own
# or any repo's): their git metadata holds absolute paths that a move would
# break. A git that fails is a refusal too, never "clean". Moves the hub,
# fixes its .gitignore line and regenerates the workai index (CLAUDE.md,
# report.py --index; committed with .gitignore); other references (memory,
# launchd, symlinks) are listed for the agent to update. WORKAI_ROOT overrides ~/workai (tests).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="${WORKAI_ROOT:-$HOME/workai}"
dry=0; from=projects; to=archives
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --restore) from=archives; to=projects; shift ;;
    *) break ;;
  esac
done
case "${1:-}" in ''|*[!0-9]*) sed -n '4,5p' "$0" | sed 's/^# *//'; exit 2 ;; esac
num="$(printf '%02d' $((10#$1)))"

hub=""; for d in "$root/$from/$num"-*; do [ -d "$d" ] && hub="$d"; done
[ -n "$hub" ] || { echo "no hub numbered $num in $from/"; exit 2; }
name="$(basename "$hub")"
[ ! -e "$root/$to/$name" ] || { echo "already exists: $to/$name"; exit 1; }

echo "Plan: $from/$name  ->  $to/$name"
stop=0
# Count linked worktrees of a repo (0 = none). A failing git prints nothing and
# returns 1: the caller treats that as STOP, never as "clean".
linked() { local out; out="$(git -C "$1" worktree list 2>/dev/null)" || return 1; echo $(( $(printf '%s\n' "$out" | wc -l) - 1 )); }
doing="$(find "$hub/backlog/doing" -name '[0-9][0-9][0-9]-*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$doing" = 0 ] || { echo "  STOP: $doing card(s) in backlog/doing; finish or release them first"; stop=1; }
if [ -e "$hub/.git" ]; then
  if n="$(linked "$hub")"; then
    [ "$n" = 0 ] || { echo "  STOP: the hub itself has $n linked worktree(s) (git -C $hub worktree list)"; stop=1; }
  else echo "  STOP: git failed on the hub; cannot check its worktrees"; stop=1; fi
fi
for repo in "$hub"/repos/*/; do
  [ -e "$repo/.git" ] || continue
  r="$(basename "$repo")"
  if n="$(linked "$repo")"; then
    [ "$n" = 0 ] || { echo "  STOP: repos/$r has $n linked worktree(s)"; stop=1; }
  else echo "  STOP: git failed on repos/$r; cannot check its worktrees"; stop=1; continue; fi
  if st="$(git -C "$repo" status --porcelain 2>/dev/null)"; then
    dirty="$(printf '%s' "$st" | grep -c . || true)"
    [ "$dirty" = 0 ] || echo "  WARNING: repos/$r has $dirty uncommitted change(s)"
  else echo "  STOP: git status failed on repos/$r"; stop=1; fi
  ahead="$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
  [ "$ahead" = 0 ] || echo "  WARNING: repos/$r has unpushed commits (or no upstream): $ahead"
done
dirty="$(git -C "$hub" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "$dirty" = 0 ] || echo "  WARNING: the hub has $dirty uncommitted change(s)"
echo "References that will need updating:"
python3 "$here/../workai-migrate/find-refs.py" "$from/$name" | sed 's/^/  /' || true
[ "$stop" = 0 ] || exit 1
[ "$dry" = 1 ] && { echo "(dry run: nothing moved)"; exit 0; }

mkdir -p "$root/$to"
mv "$hub" "$root/$to/$name"
gi="$root/.gitignore"; touch "$gi"
# Fixed strings, not regex: a "." in a name must not match other lines.
grep -vxF -e "$from/$name/" -e "$from/$name" "$gi" >"$gi.tmp" || true; mv "$gi.tmp" "$gi"
grep -qxF "$to/$name/" "$gi" || echo "$to/$name/" >>"$gi"

echo "Moved to $root/$to/$name"
indexed=1
verb="Archive"; [ "$to" = projects ] && verb="Restore"
bash "$here/../workai-open-project/regen-index.sh" "$verb hub $name" || indexed=0
[ "$indexed" = 1 ] || echo "WARNING: the workai index was NOT regenerated: run regen-index.sh (workai-open-project)"
echo "Next: update every reference listed above, then re-run:"
echo "  python3 $here/../workai-migrate/find-refs.py $from/$name"
[ "$indexed" = 1 ]
