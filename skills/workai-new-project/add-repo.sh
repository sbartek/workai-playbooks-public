#!/usr/bin/env bash
# Add an outcome repo to a hub's repos/, set up so worktrees land in the hub.
#
#   add-repo.sh HUB NAME            new empty repo repos/NAME
#   add-repo.sh HUB NAME GIT-URL    clone GIT-URL into repos/NAME
#
# Writes a local .workmux.yaml (worktree_dir: ../../worktrees/{project}) and
# keeps it out of the repo's history via .git/info/exclude, and installs the
# pre-push secret/identity scan (install-scan-hook.sh).
set -eu

hub="${1:-}"; name="${2:-}"; url="${3:-}"
[ -n "$hub" ] && [ -n "$name" ] || { sed -n '4,5p' "$0" | sed 's/^# *//'; exit 2; }
[ -f "$hub/STRUCTURE" ] || { echo "not a hub (no STRUCTURE file): $hub"; exit 2; }
repo="$hub/repos/$name"
[ ! -e "$repo" ] || { echo "already exists: $repo"; exit 1; }

if [ -n "$url" ]; then
  git clone -q "$url" "$repo"
else
  mkdir -p "$repo" && git -C "$repo" init -q -b main
fi
mkdir -p "$hub/worktrees/$name"
if [ -e "$repo/.workmux.yaml" ]; then
  # A cloned repo may track its own: never overwrite it.
  echo "NOTE: $name already has a .workmux.yaml; left alone (check its worktree_dir)" >&2
else
  printf '# Local only (excluded via .git/info/exclude): worktrees go in the hub.\nworktree_dir: ../../worktrees/{project}\n' >"$repo/.workmux.yaml"
  grep -qxF '.workmux.yaml' "$repo/.git/info/exclude" 2>/dev/null || echo ".workmux.yaml" >>"$repo/.git/info/exclude"
fi
here="$(cd "$(dirname "$0")" && pwd)"
bash "$here/install-scan-hook.sh" "$repo" >/dev/null || echo "NOTE: pre-push scan hook not installed in $name (see above)" >&2
echo "$repo"
