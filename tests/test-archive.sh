#!/usr/bin/env bash
# Tests for workai-archive-project (archive.sh) on a throwaway workai.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
skill="$here/skills/workai-archive-project"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export WORKAI_ROOT="$tmp/workai" LAUNCHD_DIR="$tmp/launchd" MEMORY_DIR="$tmp/memory" \
  SKILLS_DIRS="$tmp/skills" CRONTAB_FILE="$tmp/crontab" CLAUDE_DIR="$tmp/claude" RC_FILES="$tmp/zshrc"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -f "$tmp/out" ] && sed 's/^/     /' "$tmp/out" | head -20; fails=$((fails + 1)); }
g() { git -c user.name=t -c user.email=t@t "$@"; }

mkdir -p "$WORKAI_ROOT/projects" "$LAUNCHD_DIR" "$MEMORY_DIR" "$tmp/skills"; : >"$tmp/crontab"
printf 'projects/07-done/\nprojects/08-busy/\n' >"$WORKAI_ROOT/.gitignore"
printf '# Projects\n\n## 07 — Done\nPlan: `~/workai/projects/07-done/README.md`\n' >"$WORKAI_ROOT/CLAUDE.md"
mk() { # name
  local h="$WORKAI_ROOT/projects/$1"
  mkdir -p "$h"/backlog/{todo,doing,done,archive} "$h"/repos "$h"/worktrees
  echo 1.0.0 >"$h/STRUCTURE"; printf 'repos/\nworktrees/\n' >"$h/.gitignore"
  g -C "$h" init -q && g -C "$h" add -A && g -C "$h" commit -qm init
  mkdir -p "$h/repos/app" && g -C "$h/repos/app" init -q && echo a >"$h/repos/app/a" \
    && g -C "$h/repos/app" add -A && g -C "$h/repos/app" commit -qm a
}
mk 07-done; mk 08-busy
echo "see ~/workai/projects/07-done/" >"$MEMORY_DIR/project_done.md"

bash "$skill/archive.sh" --dry-run 7 >"$tmp/out" 2>&1 && grep -q 'memory' "$tmp/out" && [ -d "$WORKAI_ROOT/projects/07-done" ] \
  && ok "dry run lists references and moves nothing" || bad "dry run lists references and moves nothing"

bash "$skill/archive.sh" 7 >"$tmp/out" 2>&1 && ok "archives a hub" || bad "archives a hub"
[ -d "$WORKAI_ROOT/archives/07-done" ] && [ ! -e "$WORKAI_ROOT/projects/07-done" ] && ok "hub moved to archives/" || bad "hub moved to archives/"
[ "$(g -C "$WORKAI_ROOT/archives/07-done/repos/app" log -1 --format=%s)" = a ] && ok "repo intact after the move" || bad "repo intact after the move"
grep -qx 'archives/07-done/' "$WORKAI_ROOT/.gitignore" && ! grep -qx 'projects/07-done/' "$WORKAI_ROOT/.gitignore" && grep -qx 'projects/08-busy/' "$WORKAI_ROOT/.gitignore" \
  && ok "workai .gitignore updated, other lines kept" || bad "workai .gitignore updated, other lines kept"

awk '/^## Archived/{a=1} a' "$WORKAI_ROOT/CLAUDE.md" | grep -q '^- \*\*07 .*`archives/07-done/`' && ! grep -q 'projects/07-done' "$WORKAI_ROOT/CLAUDE.md" \
  && ! grep -q '^## 07' "$WORKAI_ROOT/CLAUDE.md" && ok "index regenerated: hub listed as archived, no hand section" || bad "index regenerated: hub listed as archived, no hand section"
bash "$skill/archive.sh" --restore 7 >"$tmp/out" 2>&1 && [ -d "$WORKAI_ROOT/projects/07-done" ] && grep -qx 'projects/07-done/' "$WORKAI_ROOT/.gitignore" \
  && ok "restore moves it back" || bad "restore moves it back"
awk '/^## Active/{a=1} /^## Archived/{a=0} a' "$WORKAI_ROOT/CLAUDE.md" | grep -q '`projects/07-done/`' && ! grep -q 'archives/07-done' "$WORKAI_ROOT/CLAUDE.md" \
  && ok "restore regenerates the index: hub active again" || bad "restore regenerates the index: hub active again"

h="$WORKAI_ROOT/projects/08-busy"
echo "---" >"$h/backlog/doing/003-x.md"
bash "$skill/archive.sh" 8 >"$tmp/out" 2>&1 && bad "refuses with a card in doing/" || ok "refuses with a card in doing/"
rm "$h/backlog/doing/003-x.md"
g -C "$h/repos/app" worktree add -q "$h/worktrees/app/001-x" -b card/001-x
bash "$skill/archive.sh" 8 >"$tmp/out" 2>&1 && bad "refuses with a live worktree" || ok "refuses with a live worktree"
[ -d "$h" ] && ok "refused hub left in place" || bad "refused hub left in place"

bash "$skill/archive.sh" 9 >"$tmp/out" 2>&1 && bad "refuses an unknown number" || ok "refuses an unknown number"

# the hub's own worktrees block the move too
mk 10-hubwt; h="$WORKAI_ROOT/projects/10-hubwt"
g -C "$h" worktree add -q "$h/worktrees/hub-001-draft" -b hub-001-draft
bash "$skill/archive.sh" 10 >"$tmp/out" 2>&1 && bad "refuses with a hub worktree" || { grep -q 'hub itself' "$tmp/out" && [ -d "$h" ] && ok "refuses with a hub worktree" || bad "refuses with a hub worktree"; }

# a failing git is a STOP, never "clean"
mk 11-broken; h="$WORKAI_ROOT/projects/11-broken"
rm -rf "$h/repos/app/.git" && echo "gitdir: $tmp/nowhere" >"$h/repos/app/.git"
bash "$skill/archive.sh" 11 >"$tmp/out" 2>&1 && bad "failing git stops archive" || { grep -q 'git failed' "$tmp/out" && [ -d "$h" ] && ok "failing git stops archive" || bad "failing git stops archive"; }

# .gitignore cleanup uses fixed strings
mk 12-v1.2; printf 'projects/12-v1.2/\nprojects/12-v1x2/\n' >>"$WORKAI_ROOT/.gitignore"
bash "$skill/archive.sh" 12 >"$tmp/out" 2>&1 && ! grep -qxF 'projects/12-v1.2/' "$WORKAI_ROOT/.gitignore" && grep -qxF 'projects/12-v1x2/' "$WORKAI_ROOT/.gitignore" \
  && ok ".gitignore: a dot in a name keeps the neighbour line" || bad ".gitignore: a dot in a name keeps the neighbour line"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
