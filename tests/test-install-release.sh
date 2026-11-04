#!/usr/bin/env bash
# Tests for install.sh across checkouts (second clone, worktree, release
# worktrees) and for scripts/release.sh. Works on throwaway clones of this
# checkout (files as they are now, committed there) and a throwaway skills
# folder; never ~/.claude and never this repo's tags or worktrees.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_SKILLS_DIR="$tmp/skills" WORKAI_RELEASES_DIR="$tmp/releases"
export WORKAI_INSTALL_PARTS=skills CLAUDE_CONFIG_HOME="$tmp/claude" CLAUDE_BIN="$tmp/no-claude"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
target() { readlink "$CLAUDE_SKILLS_DIR/workai-backlog"; }

# Clone A = this checkout's current files, committed, tagged v9.0.0.
git init -q "$tmp/a"
rsync -a --exclude .git --exclude __pycache__ --exclude .venv "$here/" "$tmp/a/"
git -C "$tmp/a" add -A; git -C "$tmp/a" -c core.hooksPath=/dev/null commit -q -m base; git -C "$tmp/a" branch -M main
echo "9.0.0" >"$tmp/a/VERSION"; git -C "$tmp/a" -c core.hooksPath=/dev/null commit -qam v9; git -C "$tmp/a" tag -a v9.0.0 -m 9.0.0
git clone -q "$tmp/a" "$tmp/b"
A="$tmp/a"; B="$tmp/b"

"$A/install.sh" claude >"$tmp/out" 2>&1 && [ "$(target)" = "$A/skills/workai-backlog" ] && ok "install from clone A" || bad "install from clone A"
"$B/install.sh" claude >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(target)" = "$A/skills/workai-backlog" ] && grep -q "refused.*another checkout" "$tmp/out" && ok "second clone refused without --force" || bad "second clone refused without --force"
mkdir -p "$A/skills/workai-only-in-a"; printf -- '---\nname: workai-only-in-a\ndescription: x\n---\n' >"$A/skills/workai-only-in-a/SKILL.md"
"$A/install.sh" claude >/dev/null 2>&1
"$B/install.sh" claude --force >"$tmp/out" 2>&1 && [ "$(target)" = "$B/skills/workai-backlog" ] && ok "second clone takes over with --force" || bad "second clone takes over with --force"
rm -rf "$A/skills/workai-only-in-a"
"$A/install.sh" claude --force >/dev/null 2>&1
mkdir -p "$A/skills/workai-only-in-a"; printf -- '---\nname: workai-only-in-a\ndescription: x\n---\n' >"$A/skills/workai-only-in-a/SKILL.md"
"$A/install.sh" claude >/dev/null 2>&1
"$B/install.sh" claude >"$tmp/out" 2>&1
[ -L "$CLAUDE_SKILLS_DIR/workai-only-in-a" ] && ok "another clone's extra skill is not deleted as an orphan" || bad "another clone's extra skill is not deleted as an orphan"
rm -rf "$A/skills/workai-only-in-a"; "$A/install.sh" claude >/dev/null 2>&1

git -C "$A" worktree add -q "$tmp/wt" -b card/x
"$tmp/wt/install.sh" claude >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q "linked worktree" "$tmp/out" && [ "$(target)" = "$A/skills/workai-backlog" ] && ok "worktree warns and is refused" || bad "worktree warns and is refused"
"$tmp/wt/install.sh" claude --force >"$tmp/out" 2>&1 && [ "$(target)" = "$tmp/wt/skills/workai-backlog" ] && ok "worktree takes over with --force" || bad "worktree takes over with --force"
"$A/install.sh" claude --force >/dev/null 2>&1

"$A/install.sh" claude --release >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(target)" = "$A/skills/workai-backlog" ] && ok "switch from live checkout to a release needs --force" || bad "switch from live checkout to a release needs --force"
"$A/install.sh" claude --release --force >"$tmp/out" 2>&1 && [ "$(target)" = "$tmp/releases/v9.0.0/skills/workai-backlog" ] && ok "release install links into the v9.0.0 worktree" || bad "release install links into the v9.0.0 worktree"
[ "$(git -C "$tmp/releases/v9.0.0" rev-parse HEAD)" = "$(git -C "$A" rev-parse 'v9.0.0^{commit}')" ] && ok "release worktree is at the tag" || bad "release worktree is at the tag"
git -C "$A" worktree list --porcelain | grep -A4 "releases/v9.0.0" | grep -q '^locked' && ok "release worktree is locked" || bad "release worktree is locked"
"$A/install.sh" claude --release --check >"$tmp/out" 2>&1 && ok "--release --check passes" || bad "--release --check passes"
"$A/install.sh" claude --check >"$tmp/out" 2>&1 && bad "plain --check reports links not at this checkout" || ok "plain --check reports links not at this checkout"

# A rule change, then release.sh.
"$A/scripts/release.sh" --check >"$tmp/out" 2>&1 && ok "release --check up to date right after a tag" || bad "release --check up to date right after a tag"
printf '\nNew rule.\n' >>"$A/skills/workai-backlog/SKILL.md"
python3 - "$A/CHANGELOG.md" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
open(p,"w").write(s.replace("## [Unreleased]\n", "## [Unreleased]\n\n### Changed\n- test rule\n", 1))
EOF
git -C "$A" -c core.hooksPath=/dev/null commit -qam "rule change"
"$A/scripts/release.sh" --check >"$tmp/out" 2>&1 && bad "release --check flags unreleased commits" || ok "release --check flags unreleased commits"
"$A/scripts/release.sh" 9.0.1 >"$tmp/out" 2>&1 && bad "patch refused after a rule change" || ok "patch refused after a rule change"
"$A/scripts/release.sh" 8.0.0 >"$tmp/out" 2>&1 && bad "older version refused" || ok "older version refused"
git -C "$A" config core.hooksPath /dev/null
"$A/scripts/release.sh" 9.1.0 >"$tmp/out" 2>&1 && ok "minor release cut" || bad "minor release cut"
[ "$(cat "$A/VERSION")" = 9.1.0 ] && git -C "$A" rev-parse -q --verify refs/tags/v9.1.0 >/dev/null && ok "VERSION written and v9.1.0 tagged" || bad "VERSION written and v9.1.0 tagged"
grep -q '^## \[9.1.0\] — ' "$A/CHANGELOG.md" && grep -q '^## \[Unreleased\]' "$A/CHANGELOG.md" && ok "CHANGELOG entry made, [Unreleased] kept empty" || bad "CHANGELOG entry made, [Unreleased] kept empty"
"$A/scripts/release.sh" 9.2.0 >"$tmp/out" 2>&1 && bad "empty [Unreleased] refused" || ok "empty [Unreleased] refused"

"$A/install.sh" claude --release >"$tmp/out" 2>&1 && [ "$(target)" = "$tmp/releases/v9.1.0/skills/workai-backlog" ] && ok "newer release replaces an older one without --force" || bad "newer release replaces an older one without --force"
grep -q "New rule" "$CLAUDE_SKILLS_DIR/workai-backlog/SKILL.md" && ok "the released rule is what the agent reads" || bad "the released rule is what the agent reads"
printf '\nUnreleased rule.\n' >>"$A/skills/workai-backlog/SKILL.md"; git -C "$A" commit -qam "later"
grep -q "Unreleased rule" "$CLAUDE_SKILLS_DIR/workai-backlog/SKILL.md" && bad "a later merge to main does not go live" || ok "a later merge to main does not go live"
"$A/install.sh" claude --release v9.0.0 >"$tmp/out" 2>&1 && [ "$(target)" = "$tmp/releases/v9.0.0/skills/workai-backlog" ] && ok "--release TAG goes back to an older release" || bad "--release TAG goes back to an older release"
"$A/install.sh" claude --release v7.7.7 >"$tmp/out" 2>&1 && bad "unknown tag refused" || ok "unknown tag refused"

# MCP servers follow the release too (card 01-181), with a fake `claude`
# (registrations in a folder, as in test-install-settings.sh).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF'
#!/bin/bash
mkdir -p "$FAKE_MCP"
[ "$1" = mcp ] || exit 2
case "$2" in
  get) [ -f "$FAKE_MCP/$3" ] || { echo "No MCP server named \"$3\""; exit 1; }
       printf '%s:\n  Scope: User config\n  Type: stdio\n  Command: %s\n' "$3" "$(cat "$FAKE_MCP/$3")" ;;
  add) [ "$3 $4 $6" = "--scope user --" ] || exit 3; [ -f "$FAKE_MCP/$5" ] && exit 1; echo "$7" >"$FAKE_MCP/$5" ;;
  remove) [ "$3 $4" = "--scope user" ] || exit 3; [ -f "$FAKE_MCP/$5" ] && rm "$FAKE_MCP/$5" || exit 1 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/claude"
export CLAUDE_BIN="$tmp/bin/claude" FAKE_MCP="$tmp/fake-mcp" WORKAI_INSTALL_PARTS=mcp
yt() { cat "$FAKE_MCP/youtrack"; }
man="$CLAUDE_CONFIG_HOME/workai-installed.json"
v0="$tmp/releases/v9.0.0/claude/mcp/youtrack-mcp.sh"; v1="$tmp/releases/v9.1.0/claude/mcp/youtrack-mcp.sh"
"$A/install.sh" claude --release v9.0.0 >"$tmp/out" 2>&1 && [ "$(yt)" = "$v0" ] && ok "MCP registered from release v9.0.0" || bad "MCP registered from release v9.0.0"
"$A/install.sh" claude --release >"$tmp/out" 2>&1 && [ "$(yt)" = "$v1" ] && grep -q '^replaced mcp youtrack' "$tmp/out" \
  && ok "newer release re-registers an MCP server from an older release" || bad "newer release re-registers an MCP server from an older release"
"$A/install.sh" claude --release --check >"$tmp/out" 2>&1 && grep -q '^ok       mcp youtrack' "$tmp/out" && ok "--release --check passes after the MCP move" || bad "--release --check passes after the MCP move"
echo "/my/own/youtrack" >"$FAKE_MCP/youtrack"
"$A/install.sh" claude --release v9.0.0 >"$tmp/out" 2>&1 && grep -q '^differs  mcp youtrack' "$tmp/out" && [ "$(yt)" = /my/own/youtrack ] \
  && ok "--release leaves a foreign MCP command alone" || bad "--release leaves a foreign MCP command alone"
echo "$v1" >"$FAKE_MCP/youtrack"; jq '.mcp = []' "$man" >"$man.t" && mv "$man.t" "$man"
"$A/install.sh" claude --release v9.0.0 >"$tmp/out" 2>&1 && grep -q '^differs  mcp youtrack' "$tmp/out" && [ "$(yt)" = "$v1" ] \
  && ok "--release leaves a release registration it did not record" || bad "--release leaves a release registration it did not record"

# The open-project report shows the version of the skills it belongs to.
mkdir -p "$tmp/w/projects/01-x/backlog"/{todo,doing,done,archive}; echo 1.0.0 >"$tmp/w/projects/01-x/STRUCTURE"
WORKAI_ROOT="$tmp/w" python3 "$tmp/releases/v9.1.0/skills/workai-open-project/report.py" 01 >"$tmp/out" 2>&1
grep -qx 'playbooks: 9.1.0 (release v9.1.0)' "$tmp/out" && ok "report shows the release version" || bad "report shows the release version"
WORKAI_ROOT="$tmp/w" python3 "$A/skills/workai-open-project/report.py" 01 >"$tmp/out" 2>&1
grep -qx 'playbooks: 9.1.0 (live checkout, 1 commits after v9.1.0)' "$tmp/out" && ok "report shows a live checkout as unreleased" || bad "report shows a live checkout as unreleased"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
