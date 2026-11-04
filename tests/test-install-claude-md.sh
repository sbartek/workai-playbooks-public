#!/usr/bin/env bash
# Tests for the CLAUDE.md part of install.sh (cards 01-152, 01-155). Everything
# runs in a throwaway HOME with CLAUDE_CONFIG_HOME pointing into it: never
# the real ~/.claude.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null || { echo "jq is needed"; exit 1; }
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
check() { # name, then the command
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

tpl="$here/claude/CLAUDE.md.template"
fresh() { # new throwaway HOME
  export HOME="$tmp/home$1"; rm -rf "$HOME"; mkdir -p "$HOME/.claude"
  export CLAUDE_SKILLS_DIR="$HOME/.claude/skills" CLAUDE_CONFIG_HOME="$HOME/.claude"
  export CLAUDE_BIN="$tmp/no-claude" WORKAI_RELEASES_DIR="$tmp/releases"
  C="$HOME/.claude/CLAUDE.md"; M="$HOME/.claude/workai-installed.json"
}
run() { "$here/install.sh" claude --claude-md-only "$@" >"$tmp/out" 2>&1; }
has() { grep -q "$1" "$tmp/out"; }
snap() { ls -l "$HOME/.claude"; cat "$C" 2>/dev/null; cat "$M" 2>/dev/null; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# --- the template is generic ------------------------------------------------
check "repo ships claude/CLAUDE.md.template" test -f "$tpl"
check "repo no longer ships claude/CLAUDE.md" test ! -e "$here/claude/CLAUDE.md"
check "template names no person, home folder or workai path" \
  bash -c '! grep -Eiq "bart[e]k|sbart[e]k|dys[l]ex|/Users/|/home/|workai|gdrive" "$1"' _ "$tpl"

# --- missing: template copied as a plain file ----------------------------
fresh 1
check "check reports a missing CLAUDE.md (exit 1)" bash -c '! "$1" claude --claude-md-only --check >"$2" 2>&1' _ "$here/install.sh" "$tmp/out"
check "check says missing" has '^missing  CLAUDE.md'
check "check changes nothing" test ! -e "$C"
run; check "install exits 0" test $? = 0
check "install creates a plain file, not a link" bash -c '[ -f "$1" ] && [ ! -L "$1" ]' _ "$C"
check "the file is the template" cmp -s "$C" "$tpl"
check "install says created" has '^created  CLAUDE.md'
check "manifest records created + the template's hash" \
  test "$(jq -c .claude_md "$M")" = "{\"created\":true,\"sha256\":\"$(sha "$tpl")\"}"
s="$(snap)"; run; check "second run exits 0" test $? = 0
check "second run changes nothing" test "$s" = "$(snap)"
check "second run says ours" has '^ours     CLAUDE.md'
run --check; check "check passes on our file" test $? = 0
run --uninstall; check "uninstall exits 0" test $? = 0
check "uninstall removes the untouched file and the manifest" bash -c '[ ! -e "$1" ] && [ ! -e "$2" ]' _ "$C" "$M"

# --- created, then edited: kept on uninstall ------------------------------
fresh 2
run; echo "- my own rule" >>"$C"; cp "$C" "$tmp/edited"
run; check "an edited file is kept by install" bash -c 'cmp -s "$1" "$2"' _ "$C" "$tmp/edited"
check "install says kept" has '^kept     CLAUDE.md'
run --check; check "check passes on a kept file" test $? = 0
run --uninstall; check "uninstall keeps an edited file" cmp -s "$C" "$tmp/edited"
check "uninstall says kept, drops the manifest entry" bash -c 'grep -q "^kept     CLAUDE.md" "$1" && [ ! -e "$2" ]' _ "$tmp/out" "$M"

# --- an existing plain file: untouched -----------------------------------
fresh 3
printf '# my own rules\n- local edit\n' >"$C"; cp "$C" "$tmp/mine"
s="$(snap)"; run; check "install exits 0 with a plain file there" test $? = 0
check "a plain file is untouched (content, no manifest, no backup)" test "$s" = "$(snap)"
check "install says kept" has '^kept     CLAUDE.md'
run --check; check "check passes and says kept" bash -c '[ "$1" = 0 ] && grep -q "^kept     CLAUDE.md" "$2"' _ $? "$tmp/out"
run --uninstall; check "uninstall leaves a file it did not create" cmp -s "$C" "$tmp/mine"

# --- a foreign symlink: untouched -----------------------------------------
fresh 4
echo mine >"$HOME/elsewhere.md"; ln -s "$HOME/elsewhere.md" "$C"
mkdir -p "$HOME/dotfiles/claude"; echo dots >"$HOME/dotfiles/claude/CLAUDE.md"
s="$(snap)"; run; check "install exits 0 with a foreign symlink" test $? = 0
check "a foreign symlink is untouched" bash -c '[ "$(readlink "$1")" = "$2" ]' _ "$C" "$HOME/elsewhere.md"
check "nothing else changes" test "$s" = "$(snap)"
rm "$C"; ln -s "$HOME/dotfiles/claude/CLAUDE.md" "$C"
run; check "a link into another repo's claude/CLAUDE.md is untouched" bash -c '[ "$(readlink "$1")" = "$2" ] && grep -q "^kept" "$3"' _ "$C" "$HOME/dotfiles/claude/CLAUDE.md" "$tmp/out"
rm "$C"; ln -s "$HOME/nowhere.md" "$C"
run; check "a dangling foreign symlink is untouched" bash -c '[ "$(readlink "$1")" = "$2" ]' _ "$C" "$HOME/nowhere.md"
run --uninstall; check "uninstall leaves a foreign symlink" bash -c '[ "$(readlink "$1")" = "$2" ]' _ "$C" "$HOME/nowhere.md"

# --- card 152's link: replaced by an identical plain file ----------------
# A throwaway git repo stands in for workai-playbooks, with the history of a
# claude/CLAUDE.md that was released (tag v1.5.0), edited, then removed.
fake="$tmp/fake-playbooks"
mkgit() { # dir, then a command
  local d="$1"; shift
  git -C "$d" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@" >/dev/null 2>&1
}
mkdir -p "$fake/claude" "$fake/skills/workai-structure"
cp "$here/install.sh" "$fake/"; cp "$tpl" "$fake/claude/"; touch "$fake/skills/workai-structure/SKILL.md"
git init -q "$fake"
echo "rules v1" >"$fake/claude/CLAUDE.md"; mkgit "$fake" add -A; mkgit "$fake" commit -qm v1; mkgit "$fake" tag v1.5.0
echo "rules v2" >"$fake/claude/CLAUDE.md"; mkgit "$fake" commit -qam v2
mkgit "$fake" rm -q claude/CLAUDE.md; mkgit "$fake" commit -qm "remove the personal file"
check "the fake repo is set up (v1 tagged, v2 last, file removed)" bash -c \
  '[ "$(git -C "$1" show v1.5.0:claude/CLAUDE.md)" = "rules v1" ] && [ "$(git -C "$1" show HEAD^:claude/CLAUDE.md)" = "rules v2" ] && [ ! -e "$1/claude/CLAUDE.md" ]' _ "$fake"
frun() { "$fake/install.sh" claude --claude-md-only "$@" >"$tmp/out" 2>&1; }

# a release that still exists
fresh 5
rel="$tmp/releases/v9.9.9"; mkdir -p "$rel/claude"
printf '# old global rules\n- personal line\n' >"$rel/claude/CLAUDE.md"
ln -s "$rel/claude/CLAUDE.md" "$C"
echo '{"version":1,"claude_md":{"backup":"'"$HOME"'/.claude/CLAUDE.md.workai-1.bak","installed":true}}' >"$M"
frun --check; check "check reports the old link (exit 1)" bash -c '[ "$1" != 0 ] && grep -q "^linked   CLAUDE.md" "$2"' _ $? "$tmp/out"
check "check leaves the link" test -L "$C"
frun; check "migration exits 0" test $? = 0
check "the link is now a plain file" bash -c '[ -f "$1" ] && [ ! -L "$1" ]' _ "$C"
check "with the link target's content" cmp -s "$C" "$rel/claude/CLAUDE.md"
check "install says migrated" has '^migrated CLAUDE.md'
check "the old manifest entry is gone" test ! -e "$M"
s="$(snap)"; frun; check "a run after migration changes nothing and says kept" bash -c '[ "$1" = "$2" ] && grep -q "^kept" "$3"' _ "$s" "$(snap)" "$tmp/out"
frun --uninstall; check "uninstall keeps the migrated file" cmp -s "$C" "$rel/claude/CLAUDE.md"

# another checkout that still exists (install.sh + skills, no git)
fresh 6
co="$tmp/clone"; mkdir -p "$co/claude" "$co/skills/workai-structure"
touch "$co/install.sh" "$co/skills/workai-structure/SKILL.md"; echo "clone rules" >"$co/claude/CLAUDE.md"
ln -s "$co/claude/CLAUDE.md" "$C"
frun; check "a link into another checkout is migrated to a plain copy" bash -c '[ ! -L "$1" ] && [ "$(cat "$1")" = "clone rules" ]' _ "$C"

# a release that is gone, tag unknown: check and install both say refused
fresh 7
ln -s "$tmp/releases/v0.0.1/claude/CLAUDE.md" "$C"
frun --check; check "check says install would refuse a gone, unknown release" bash -c '[ "$1" != 0 ] && grep -q "^refused  CLAUDE.md" "$2"' _ $? "$tmp/out"
frun; check "install refuses it (exit 1) and leaves the link" bash -c '[ "$1" != 0 ] && [ -L "$2" ] && grep -q "^refused  CLAUDE.md" "$3"' _ $? "$C" "$tmp/out"

# a release that is gone, tag known: the tag's file
fresh 8
ln -s "$tmp/releases/v1.5.0/claude/CLAUDE.md" "$C"
frun --check; check "check names the tag as the source" bash -c '[ "$1" != 0 ] && grep -q "^linked   CLAUDE.md.*v1.5.0" "$2" && [ -L "$3" ]' _ $? "$tmp/out" "$C"
frun; check "a link into a gone release is migrated from its tag" bash -c '[ "$1" = 0 ] && [ ! -L "$2" ] && [ "$(cat "$2")" = "rules v1" ]' _ $? "$C"

# a live link into the checkout whose claude/CLAUDE.md is gone: from git
fresh 9
ln -s "$fake/claude/CLAUDE.md" "$C"
frun; check "a live link whose repo file is gone is migrated from git history" \
  bash -c '[ "$1" = 0 ] && [ ! -L "$2" ] && [ "$(cat "$2")" = "rules v2" ] && grep -q "^migrated CLAUDE.md" "$3"' _ $? "$C" "$tmp/out"

# a link into a deleted checkout, known by card 152's manifest entry
fresh 10
ln -s "$tmp/deleted-clone/claude/CLAUDE.md" "$C"
echo '{"version":1,"claude_md":{"backup":null,"installed":true}}' >"$M"
frun; check "a link into a deleted checkout is migrated from this repo's history" \
  bash -c '[ "$1" = 0 ] && [ ! -L "$2" ] && [ "$(cat "$2")" = "rules v2" ]' _ $? "$C"

# a link into another git checkout whose file is gone: its own history first
fresh 11
co2="$tmp/clone2"; git clone -q "$fake" "$co2" 2>/dev/null; mkgit "$co2" checkout -q HEAD~1
echo "rules edited in clone2" >"$co2/claude/CLAUDE.md"; mkgit "$co2" commit -qam edit; mkgit "$co2" rm -q claude/CLAUDE.md; mkgit "$co2" commit -qm rm
ln -s "$co2/claude/CLAUDE.md" "$C"
frun; check "a gone file in another git checkout comes from that checkout's history" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "rules edited in clone2" ]' _ $? "$C"

# uninstall of a 152 link that was never migrated: undone as 152 did
fresh 12
echo "the original" >"$HOME/.claude/CLAUDE.md.workai-1.bak"
ln -s "$rel/claude/CLAUDE.md" "$C"
echo '{"version":1,"claude_md":{"backup":"'"$HOME"'/.claude/CLAUDE.md.workai-1.bak","installed":true}}' >"$M"
frun --uninstall; check "uninstall removes an old link and restores its backup" \
  bash -c '[ "$1" = 0 ] && [ ! -L "$2" ] && [ "$(cat "$2")" = "the original" ] && [ ! -e "$3" ]' _ $? "$C" "$M"

# a broken manifest: nothing is written
fresh 13
echo '{not json' >"$M"
frun; check "a broken manifest: install refuses before writing CLAUDE.md" bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ $? "$C"

# --- other parts untouched; nothing installed -> uninstall exits 0 --------
fresh 14
"$here/install.sh" claude --skills-only >"$tmp/out" 2>&1; check "--skills-only leaves CLAUDE.md alone" test ! -e "$C"
WORKAI_INSTALL_PARTS=claudemd "$here/install.sh" claude --uninstall >"$tmp/out" 2>&1
check "uninstall with nothing installed exits 0" test $? = 0

if [ "$fails" -gt 0 ]; then echo "$fails test(s) failed"; exit 1; fi
echo "all tests pass"
