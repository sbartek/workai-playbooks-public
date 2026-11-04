#!/usr/bin/env bash
# Tests for install.sh against a throwaway skills folder (never ~/.claude).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_SKILLS_DIR="$tmp/skills"
# Skills only here (settings and MCP: test-install-settings.sh); never the real ~/.claude or claude CLI.
export WORKAI_INSTALL_PARTS=skills CLAUDE_CONFIG_HOME="$tmp/claude" CLAUDE_BIN="$tmp/no-claude"
fails=0
skills="$(cd "$here/skills" && ls -d */ | tr -d / )"

run() { "$here/install.sh" claude "$@" >"$tmp/out" 2>&1; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }

# A skill the user already has, which must never be touched.
mkdir -p "$CLAUDE_SKILLS_DIR/worktree"; echo keep >"$CLAUDE_SKILLS_DIR/worktree/SKILL.md"

run --check && bad "check fails before install" || ok "check fails before install"

run && ok "install exits 0" || bad "install exits 0"
for s in $skills; do
  [ "$(readlink "$CLAUDE_SKILLS_DIR/$s")" = "$here/skills/$s" ] && ok "linked $s" || bad "linked $s"
done

before="$(ls -l "$CLAUDE_SKILLS_DIR")"
run && [ "$(ls -l "$CLAUDE_SKILLS_DIR")" = "$before" ] && ok "second install changes nothing" || bad "second install changes nothing"

run --check && ok "check passes after install" || bad "check passes after install"

first="$(echo "$skills" | head -1)"
rm "$CLAUDE_SKILLS_DIR/$first"; ln -s "/moved/away/skills/$first" "$CLAUDE_SKILLS_DIR/$first"
run --check && bad "check reports a broken link" || ok "check reports a broken link"
run && [ "$(readlink "$CLAUDE_SKILLS_DIR/$first")" = "$here/skills/$first" ] && ok "install repairs a broken link" || bad "install repairs a broken link"

ln -s "/old/clone/skills/workai-gone" "$CLAUDE_SKILLS_DIR/workai-gone"
run --check && bad "check reports an orphan link" || ok "check reports an orphan link"
run && [ ! -L "$CLAUDE_SKILLS_DIR/workai-gone" ] && ok "install removes an orphan link" || bad "install removes an orphan link"

rm "$CLAUDE_SKILLS_DIR/$first"; mkdir "$CLAUDE_SKILLS_DIR/$first"
run && bad "install refuses a foreign folder" || ok "install refuses a foreign folder"
[ -d "$CLAUDE_SKILLS_DIR/$first" ] && [ ! -L "$CLAUDE_SKILLS_DIR/$first" ] && ok "foreign folder left intact" || bad "foreign folder left intact"
rmdir "$CLAUDE_SKILLS_DIR/$first"; run >/dev/null

run --uninstall && ok "uninstall exits 0" || bad "uninstall exits 0"
left="$(ls "$CLAUDE_SKILLS_DIR")"
[ "$left" = "worktree" ] && ok "uninstall leaves only the user's own skill" || bad "uninstall leaves only the user's own skill (left: $left)"
[ "$(cat "$CLAUDE_SKILLS_DIR/worktree/SKILL.md")" = keep ] && ok "user's skill untouched" || bad "user's skill untouched"

# --- tools in a throwaway bin dir ---------------------------------------------
export WORKAI_BIN_DIR="$tmp/bin"
T="$WORKAI_BIN_DIR/workai-secret"
WORKAI_INSTALL_PARTS=tools run && [ "$(readlink "$T")" = "$here/tools/workai-secret/workai-secret" ] && ok "tools: workai-secret linked" || bad "tools: workai-secret linked"
[ ! -e "$WORKAI_BIN_DIR/workai-board" ] && [ ! -e "$WORKAI_BIN_DIR/kanboard-sync" ] && ok "tools: only tools/workai-X/workai-X executables" || bad "tools: only tools/workai-X/workai-X executables"
WORKAI_INSTALL_PARTS=tools run --check && ok "tools: --check passes after install" || bad "tools: --check passes after install"
echo mine >"$WORKAI_BIN_DIR/workai-other"
rm "$T"; echo mine >"$T"
WORKAI_INSTALL_PARTS=tools run && bad "tools: refuses a file it did not install" || { [ "$(cat "$T")" = mine ] && ok "tools: refuses a file it did not install" || bad "tools: refuses a file it did not install"; }
rm "$T"; ln -s "/gone/checkout/tools/workai-secret/workai-secret" "$T"
WORKAI_INSTALL_PARTS=tools run && [ "$(readlink "$T")" = "$here/tools/workai-secret/workai-secret" ] && ok "tools: repairs a link into a gone checkout" || bad "tools: repairs a link into a gone checkout"
WORKAI_INSTALL_PARTS=tools run --uninstall && [ ! -e "$T" ] && [ "$(cat "$WORKAI_BIN_DIR/workai-other")" = mine ] && ok "tools: uninstall removes only its links" || bad "tools: uninstall removes only its links"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
