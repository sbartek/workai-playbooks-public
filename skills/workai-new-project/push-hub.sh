#!/usr/bin/env bash
# Scan a hub (or outcome repo) for secrets and identity documents, then push
# it to its private GitHub repo. Stops on any hit; never creates a public repo.
#
#   push-hub.sh PATH OWNER/NAME     e.g. push-hub.sh ~/workai/projects/42-x sbartek/42-x
#   push-hub.sh --scan-only PATH    scan and install the pre-push hook, no push
#
# The scan (scan.py next to this file) reads every file in the whole history.
# It also installs a pre-push hook in PATH, so a later plain `git push` is
# scanned too. With a remote `origin` already set it runs `git push`;
# otherwise `gh repo create OWNER/NAME --private --source=PATH --push`.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
scan_only=0; [ "${1:-}" = "--scan-only" ] && { scan_only=1; shift; }
path="${1:-}"; slug="${2:-}"
usage() { sed -n '5,6p' "$0" | sed 's/^# *//'; exit 2; }
[ -n "$path" ] || usage
[ "$scan_only" = 1 ] || [ -n "$slug" ] || usage
git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $path"; exit 2; }

bash "$here/install-scan-hook.sh" "$path" || exit 2
python3 "$here/scan.py" "$path"; rc=$?
[ "$rc" = 0 ] || { echo "push-hub: STOP, nothing pushed (scan exit $rc)"; exit 1; }
[ "$scan_only" = 1 ] && exit 0

if git -C "$path" remote get-url origin >/dev/null 2>&1; then
  git -C "$path" push -u origin HEAD
else
  gh repo create "$slug" --private --source="$path" --push
fi
