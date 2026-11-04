#!/usr/bin/env bash
# Install a pre-push hook that runs scan.py on the repo before every push.
#
#   install-scan-hook.sh REPO
#
# The scanner is copied into the repo's hooks folder, so the hook keeps
# working if this skill folder moves. An existing pre-push hook that is not
# ours is left alone (reported, exit 1), except Git LFS's own hook: the scan
# then runs first and `git lfs pre-push` after it, in one hook.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="${1:-}"
[ -n "$repo" ] || { sed -n '4p' "$0" | sed 's/^# *//'; exit 2; }
hooks="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)" || { echo "not a git repo: $repo"; exit 2; }
case "$hooks" in /*) ;; *) hooks="$repo/$hooks" ;; esac
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
case "$(cd "$hooks" 2>/dev/null && pwd -P)/" in
  "$common"/*) ;;   # the usual .git/hooks
  "$(cd "$top" && pwd -P)"/*)
    # core.hooksPath points into the work tree (a tracked hooks folder): a
    # copy there would be an untracked file. The repo must track its own hook.
    if [ -e "$hooks/pre-push" ] && grep -q "# workai pre-push scan" "$hooks/pre-push"; then exit 0; fi
    echo "install-scan-hook: $repo keeps its hooks in the work tree ($hooks); add a tracked pre-push that runs scan.py"
    exit 1 ;;
esac
mkdir -p "$hooks"
hook="$hooks/pre-push"
marker="# workai pre-push scan"
lfs=0
[ -e "$hook" ] && grep -q '^git lfs pre-push' "$hook" && lfs=1
if [ -e "$hook" ] && ! grep -q "$marker" "$hook" && [ "$lfs" = 0 ]; then
  echo "install-scan-hook: $hook exists and is not ours; add a call to workai-scan.py by hand"
  exit 1
fi
cp "$here/scan.py" "$hooks/workai-scan.py"
cat >"$hook" <<EOF
#!/bin/sh
$marker (installed by workai-new-project/install-scan-hook.sh)
python3 "\$(dirname "\$0")/workai-scan.py" "\$(git rev-parse --show-toplevel)" || {
  echo "pre-push: workai scan found secrets or identity documents; push stopped"
  exit 1
}
EOF
if [ "$lfs" = 1 ]; then
  cat >>"$hook" <<'EOF'
# Git LFS (was this repo's pre-push hook before the scan was added)
command -v git-lfs >/dev/null 2>&1 || { printf >&2 "\n%s\n\n" "This repository is configured for Git LFS but 'git-lfs' was not found on your path."; exit 2; }
git lfs pre-push "$@"
EOF
fi
chmod +x "$hook"
