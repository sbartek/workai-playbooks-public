#!/usr/bin/env bash
# Regenerate the workai index (WORKAI_ROOT/CLAUDE.md) with `report.py --index`
# and commit it, under the shared-file lock. The index is never edited by
# hand: new-project.sh, migrate.sh and archive.sh call this after they add or
# move a hub, and an agent runs it after changing a hub README's goal or
# `<!-- index: ... -->` line.
#
#   regen-index.sh [MESSAGE]     MESSAGE is the commit message
#
# Lock: if the caller already holds it (WORKAI_LOCK_OWNER names the owner, or
# the lock's session/pid is this Claude session's), it is used as is;
# otherwise the script takes it (waiting up to WORKAI_LOCK_TIMEOUT seconds,
# default 600) and releases it at the end. A lock held by WORKAI_LOCK_OWNER's
# name must exist when that variable is set.
#
# Commit: when WORKAI_ROOT is the top of a git repo, CLAUDE.md and .gitignore
# (the lines new-project, migrate and archive write) are committed, those two
# paths only, and only if they changed. Nothing is pushed.
# WORKAI_ROOT overrides ~/workai (tests). Exit 1 if the index was not written.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="${WORKAI_ROOT:-$HOME/workai}"
msg="${1:-Regenerate the workai index}"
lock="$root/.workai.lock"
locksh="$here/../workai-migrate/lock.sh"

field() { sed -n "s/^$1=//p" "$lock/owner" 2>/dev/null | head -1; }
mine=""   # owner name we took the lock under, to release at the end
if [ -n "${WORKAI_LOCK_OWNER:-}" ]; then
  [ -d "$lock" ] && [ "$(field owner)" = "$WORKAI_LOCK_OWNER" ] \
    || { echo "regen-index: the lock is not held by $WORKAI_LOCK_OWNER" >&2; exit 1; }
elif [ -d "$lock" ] && { { [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$(field session)" = "$CLAUDE_CODE_SESSION_ID" ]; } \
    || { [ -n "${CLAUDE_PID:-}" ] && [ "$(field pid)" = "$CLAUDE_PID" ]; }; }; then
  :   # held by this session
else
  mine="regen-index $$"
  LOCK_PID=$$ bash "$locksh" take "$mine" "${WORKAI_LOCK_TIMEOUT:-600}" >/dev/null || exit 1
fi
release() { [ -z "$mine" ] || bash "$locksh" release "$mine" >/dev/null; }
trap release EXIT

tmpf="$root/.CLAUDE.md.regen.$$"
if ! python3 "$here/report.py" --index "$root" >"$tmpf"; then
  rm -f "$tmpf"; echo "regen-index: report.py --index failed; $root/CLAUDE.md left as it was" >&2; exit 1
fi
mv "$tmpf" "$root/CLAUDE.md"
echo "index regenerated: $root/CLAUDE.md"

top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ "$(cd "$top" && pwd -P)" = "$(cd "$root" && pwd -P)" ] || exit 0
paths=(CLAUDE.md); [ -e "$root/.gitignore" ] && paths+=(.gitignore)
git -C "$root" add -- "${paths[@]}" || exit 1
if git -C "$root" diff --cached --quiet -- "${paths[@]}"; then exit 0; fi
git -C "$root" commit -q -m "$msg" -- "${paths[@]}" || { echo "regen-index: commit failed in $root" >&2; exit 1; }
echo "committed in $root: $msg"
