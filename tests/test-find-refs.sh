#!/usr/bin/env bash
# Tests for skills/workai-migrate/find-refs.py: what it scans and where a path ends.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
refs="$here/skills/workai-migrate/find-refs.py"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export WORKAI_ROOT="$tmp/workai" LAUNCHD_DIR="$tmp/launchd" MEMORY_DIR="$tmp/memory" \
  SKILLS_DIRS="$tmp/skills" CRONTAB_FILE="$tmp/crontab" CLAUDE_DIR="$tmp/claude" RC_FILES="$tmp/zshrc:$tmp/bashrc"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
mkdir -p "$WORKAI_ROOT/projects/ceramics" "$WORKAI_ROOT/projects/01-other/notes" "$LAUNCHD_DIR" "$MEMORY_DIR" "$tmp/skills" "$tmp/claude"
: >"$tmp/crontab"
o="$WORKAI_ROOT/projects/01-other/notes"
printf 'Moved, see projects/ceramics.\n' >"$o/dot.md"
printf 'Not it: projects/ceramics.md and projects/ceramics.v2 and projects/ceramics-extra\n' >"$o/notit.md"
printf 'Ceramics lives in ~/workai/projects/ceramics, read it.\n' >"$tmp/claude/MEMORY.md"
printf 'Always check projects/ceramics\n' >"$tmp/claude/CLAUDE.md"
printf '{"hooks": {"SessionStart": [{"command": "%s/projects/ceramics/start.sh"}]}}\n' "$WORKAI_ROOT" >"$tmp/claude/settings.json"
printf '{"permissions": {"allow": ["Read(~/workai/projects/ceramics/**)"]}}\n' >"$tmp/claude/settings.local.json"
printf 'alias cer="cd ~/workai/projects/ceramics"\n' >"$tmp/zshrc"
printf 'export X=1\n' >"$tmp/bashrc"

python3 "$refs" projects/ceramics >"$tmp/out" 2>&1
[ $? -eq 1 ] && ok "references found: exit 1" || bad "exit code"
grep -q "^   file .*dot.md:1  Moved, see projects/ceramics\.$" "$tmp/out" && ok "trailing full stop counts" || bad "trailing full stop"
grep -q "notit.md" "$tmp/out" && bad "ceramics.md / ceramics.v2 / ceramics-extra are other paths" || ok "ceramics.md / ceramics.v2 / ceramics-extra are other paths"
grep -q "^   claude .*claude/MEMORY.md:1 " "$tmp/out" && ok "scans ~/.claude/MEMORY.md" || bad "MEMORY.md"
grep -q "^   claude .*claude/CLAUDE.md:1 " "$tmp/out" && ok "scans ~/.claude/CLAUDE.md" || bad "CLAUDE.md"
grep -q "^   claude .*claude/settings.json:1 " "$tmp/out" && ok "scans settings hooks" || bad "settings.json"
grep -q "^   claude .*claude/settings.local.json:1 " "$tmp/out" && ok "scans settings.local.json rules" || bad "settings.local.json"
grep -q "Read(~/workai" "$tmp/out" && bad "settings lines are never echoed (secrets)" || ok "settings lines are never echoed (secrets)"
grep -q "^   shell rc .*zshrc:1 " "$tmp/out" && ok "scans shell rc files" || bad "zshrc"
grep -q "bashrc" "$tmp/out" && bad "unrelated rc not listed" || ok "unrelated rc not listed"
[ "$(grep -c '^   ' "$tmp/out")" -eq 6 ] && ok "exactly six references" || bad "count"

rm -rf "$tmp/claude" "$tmp/zshrc" "$o"
python3 "$refs" projects/ceramics >"$tmp/out" 2>&1
[ $? -eq 0 ] && grep -q "0 reference(s)" "$tmp/out" && ok "missing files are fine, nothing found: exit 0" || bad "clean run"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
