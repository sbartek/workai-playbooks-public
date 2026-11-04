#!/usr/bin/env bash
# Tests for workai-migrate (migrate.sh, find-refs.py) on a throwaway workai.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
skill="$here/skills/workai-migrate"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export WORKAI_ROOT="$tmp/workai" LAUNCHD_DIR="$tmp/launchd" MEMORY_DIR="$tmp/memory" \
  SKILLS_DIRS="$tmp/skills" CRONTAB_FILE="$tmp/crontab" CLAUDE_DIR="$tmp/claude" RC_FILES="$tmp/zshrc"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -f "$tmp/out" ] && sed 's/^/     /' "$tmp/out" | head -30; fails=$((fails + 1)); }
g() { git -c user.name=t -c user.email=t@t "$@"; }

P="$WORKAI_ROOT/projects"
mkdir -p "$P/01-first" "$WORKAI_ROOT/archives" "$LAUNCHD_DIR" "$MEMORY_DIR" "$tmp/skills"
printf '# Projects\n\n## 01 — First\n\n## L38 — Ceramics\nPlan: `~/workai/projects/ceramics/README.md`\n' >"$WORKAI_ROOT/CLAUDE.md"
printf 'projects/01-first/\nprojects/ceramics/\nprojects/ceramics-extra/\n' >"$WORKAI_ROOT/.gitignore"
mkdir -p "$P/ceramics" && g -C "$P/ceramics" init -q && echo hi >"$P/ceramics/README.md" && g -C "$P/ceramics" add -A && g -C "$P/ceramics" commit -qm init
mkdir -p "$P/ceramics-extra" && echo other >"$P/ceramics-extra/x"
mkdir -p "$P/seguro/docs" && echo plan >"$P/seguro/PLAN.md"
echo "# plan" >"$P/mudanza.md"; echo "print(1)" >"$P/mudanza-calc.py"
echo "<string>$P/ceramics/run.sh</string>" >"$LAUNCHD_DIR/com.test.ceramics.plist"
echo "0 9 * * * $P/ceramics/sync.sh" >"$tmp/crontab"
echo "Work in ~/workai/projects/ceramics/ but not projects/ceramics-extra" >"$MEMORY_DIR/project_ceramics.md"
ln -s "$P/ceramics/skills/x" "$tmp/skills/x"
mkdir -p "$P/other" && echo "see $P/ceramics/README.md" >"$P/other/notes.md"

# find-refs
python3 "$skill/find-refs.py" projects/ceramics >"$tmp/out"; rc=$?
[ $rc = 1 ] && ok "find-refs exits 1 when something points at the path" || bad "find-refs exits 1"
for k in launchd crontab workai memory symlink file; do
  grep -q "^   $k " "$tmp/out" && ok "find-refs sees $k" || bad "find-refs sees $k"
done
grep -q 'ceramics-extra' "$tmp/out" && grep -q 'gitignore:3' "$tmp/out" && bad "find-refs ignores ceramics-extra" || ok "find-refs ignores ceramics-extra"
python3 "$skill/find-refs.py" projects/nothing-here >"$tmp/out"; [ $? = 0 ] && ok "find-refs exits 0 when nothing points at it" || bad "find-refs exits 0"

# dry run moves nothing
bash "$skill/migrate.sh" --dry-run ceramics "Ceramics" ceramics >"$tmp/out" 2>&1
[ -d "$P/ceramics" ] && ! ls -d "$P"/02-* >/dev/null 2>&1 && grep -q 'repos/ceramics' "$tmp/out" && ok "dry run plans and moves nothing" || bad "dry run plans and moves nothing"

# git repo -> repos/
bash "$skill/migrate.sh" ceramics "Ceramics" ceramics >"$tmp/out" 2>&1 && ok "migrates a git repo" || bad "migrates a git repo"
hub="$P/02-ceramics"
[ -d "$hub/repos/ceramics/.git" ] && [ ! -e "$P/ceramics" ] && ok "repo moved to repos/ceramics" || bad "repo moved to repos/ceramics"
[ "$(g -C "$hub/repos/ceramics" log -1 --format=%s)" = init ] && ok "repo history intact" || bad "repo history intact"
[ -z "$(g -C "$hub/repos/ceramics" status --porcelain)" ] && ok ".workmux.yaml excluded" || bad ".workmux.yaml excluded"
[ -x "$hub/repos/ceramics/.git/hooks/pre-push" ] && grep -q '# workai pre-push scan' "$hub/repos/ceramics/.git/hooks/pre-push" && ok "migrated repo gets the pre-push scan" || bad "migrated repo gets the pre-push scan"
[ -z "$(g -C "$hub" status --porcelain)" ] && [ -f "$hub/STRUCTURE" ] && ok "hub committed with STRUCTURE" || bad "hub committed with STRUCTURE"
grep -qx 'projects/02-ceramics/' "$WORKAI_ROOT/.gitignore" && ! grep -qx 'projects/ceramics/' "$WORKAI_ROOT/.gitignore" && grep -qx 'projects/ceramics-extra/' "$WORKAI_ROOT/.gitignore" && ok "workai .gitignore swapped, neighbours kept" || bad "workai .gitignore swapped, neighbours kept"
# The index is regenerated, never hand-edited (card 01-151): the old L38 section goes.
head -1 "$WORKAI_ROOT/CLAUDE.md" | grep -qx '# Workai index' && grep -q '^- \*\*02 Ceramics\*\*.*`projects/02-ceramics/` repos: ceramics' "$WORKAI_ROOT/CLAUDE.md" \
  && ok "index regenerated, lists the migrated hub" || bad "index regenerated, lists the migrated hub"
! grep -q '^## [0-9L][0-9]' "$WORKAI_ROOT/CLAUDE.md" && ok "no hand-written ## NN or ## Lnn section" || bad "no hand-written ## NN or ## Lnn section"
[ ! -e "$WORKAI_ROOT/.workai.lock" ] && ok "lock released" || bad "lock released"

# plain folder -> notes/
bash "$skill/migrate.sh" seguro-reclamacion "Seguro" seguro >"$tmp/out" 2>&1 && [ -f "$P/03-seguro-reclamacion/notes/seguro/PLAN.md" ] && ok "plain folder moved to notes/" || bad "plain folder moved to notes/"

# several files
bash "$skill/migrate.sh" mudanza "Mudanza" mudanza.md mudanza-calc.py >"$tmp/out" 2>&1 \
  && [ -f "$P/04-mudanza/notes/mudanza.md" ] && [ -f "$P/04-mudanza/notes/mudanza-calc.py" ] && ok "files moved to notes/" || bad "files moved to notes/"

# refusals
bash "$skill/migrate.sh" x "X" 01-first >"$tmp/out" 2>&1 && bad "refuses a hub" || ok "refuses a hub"
bash "$skill/migrate.sh" x "X" missing >"$tmp/out" 2>&1 && bad "refuses a missing item" || ok "refuses a missing item"
mkdir -p "$P/busy" && g -C "$P/busy" init -q && echo a >"$P/busy/a" && g -C "$P/busy" add -A && g -C "$P/busy" commit -qm a
g -C "$P/busy" worktree add -q "$tmp/wt" -b feature
bash "$skill/migrate.sh" busy "Busy" busy >"$tmp/out" 2>&1 && bad "refuses a repo with worktrees" || ok "refuses a repo with worktrees"
[ -d "$P/busy" ] && ok "refused repo left in place" || bad "refused repo left in place"

# validation comes first: nothing printed as a plan, nothing created
bash "$skill/migrate.sh" --dry-run Bad_Name "X" seguro >"$tmp/out" 2>&1; rc=$?
[ $rc = 2 ] && ! grep -q 'Plan' "$tmp/out" && ok "bad name refused before the plan" || bad "bad name refused before the plan"
mkdir -p "$P/dupe" && echo d >"$P/dupe/x"
bash "$skill/migrate.sh" dupe "Dupe" dupe dupe >"$tmp/out" 2>&1; rc=$?
[ $rc = 2 ] && grep -q 'twice' "$tmp/out" && [ -d "$P/dupe" ] && ! ls -d "$P"/[0-9][0-9]-dupe >/dev/null 2>&1 && ok "duplicate item refused, nothing created" || bad "duplicate item refused, nothing created"
bash "$skill/migrate.sh" ceramics "Again" dupe >"$tmp/out" 2>&1 && bad "refuses an existing hub name" || { grep -q 'already exists' "$tmp/out" && [ -d "$P/dupe" ] && ok "refuses an existing hub name" || bad "refuses an existing hub name"; }

# a tracked .workmux.yaml in the moved repo is left alone
mkdir -p "$P/wm" && g -C "$P/wm" init -q && printf 'worktree_dir: custom\n' >"$P/wm/.workmux.yaml" && g -C "$P/wm" add -A && g -C "$P/wm" commit -qm wm
bash "$skill/migrate.sh" wm "WM" wm >"$tmp/out" 2>&1 && ok "migrates a repo with its own .workmux.yaml" || bad "migrates a repo with its own .workmux.yaml"
wmhub="$(ls -d "$P"/[0-9][0-9]-wm)"
[ "$(cat "$wmhub/repos/wm/.workmux.yaml")" = "worktree_dir: custom" ] && [ -z "$(g -C "$wmhub/repos/wm" status --porcelain)" ] && grep -q 'tracks its own' "$tmp/out" \
  && ok "tracked .workmux.yaml not overwritten, reported" || bad "tracked .workmux.yaml not overwritten, reported"

# .gitignore cleanup uses fixed strings: a "." does not eat a neighbour
echo "a" >"$P/v1.2"; printf 'projects/v1.2\nprojects/v1x2/\n' >>"$WORKAI_ROOT/.gitignore"
bash "$skill/migrate.sh" vdot "Vdot" v1.2 >"$tmp/out" 2>&1 \
  && ! grep -qxF 'projects/v1.2' "$WORKAI_ROOT/.gitignore" && grep -qxF 'projects/v1x2/' "$WORKAI_ROOT/.gitignore" \
  && ok ".gitignore: a dot in a name keeps the neighbour line" || bad ".gitignore: a dot in a name keeps the neighbour line"

# a migration that fails half-way resumes on the second run
echo one >"$P/r1.txt"; mkdir -p "$P/r2" && echo two >"$P/r2/f" && chmod a-w "$P/r2"
bash "$skill/migrate.sh" resum "Resum" r1.txt r2 >"$tmp/out" 2>&1 && bad "half-way failure exits non-zero" || ok "half-way failure exits non-zero"
rhub="$(ls -d "$P"/[0-9][0-9]-resum 2>/dev/null)"
[ -n "$rhub" ] && [ -f "$rhub/notes/r1.txt" ] && [ -d "$P/r2" ] && [ -f "$rhub/.git/workai-migrating" ] && ok "half-way state: hub marked unfinished" || bad "half-way state: hub marked unfinished"
chmod u+w "$P/r2"
bash "$skill/migrate.sh" resum "Resum" r1.txt r2 >"$tmp/out" 2>&1 && ok "re-run resumes" || bad "re-run resumes"
[ -f "$rhub/notes/r2/f" ] && [ ! -e "$P/r2" ] && [ ! -e "$rhub/.git/workai-migrating" ] && [ -z "$(g -C "$rhub" status --porcelain)" ] \
  && [ "$(ls -d "$P"/[0-9][0-9]-resum | wc -l | tr -d ' ')" = 1 ] && [ "$(grep -cxF "projects/$(basename "$rhub")/" "$WORKAI_ROOT/.gitignore")" = 1 ] \
  && ok "resumed: everything moved, one hub, committed, one .gitignore line" || bad "resumed: everything moved, one hub, committed, one .gitignore line"
bash "$skill/migrate.sh" resum "Resum" r1.txt r2 >"$tmp/out" 2>&1 && bad "finished migration is not re-run" || ok "finished migration is not re-run"

# a failing git is a STOP
mkdir -p "$P/broken/.git" && echo junk >"$P/broken/.git/HEAD"
bash "$skill/migrate.sh" broken "Broken" broken >"$tmp/out" 2>&1 && bad "failing git stops migrate" || { grep -q 'STOP' "$tmp/out" && [ -d "$P/broken" ] && ok "failing git stops migrate" || bad "failing git stops migrate"; }

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
