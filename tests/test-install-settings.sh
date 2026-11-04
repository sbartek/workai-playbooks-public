#!/usr/bin/env bash
# Tests for the settings and MCP parts of install.sh, and for the YouTrack
# MCP wrapper. Everything runs in a throwaway HOME with a fake `claude` CLI
# (registrations kept in a folder) and fake `security`/`npx`: never the real
# ~/.claude, ~/.claude.json, keychain or network.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null || { echo "jq is needed"; exit 1; }
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }

# Fake claude: `mcp get|add|remove`, state in $FAKE_MCP, every call logged.
fakebin="$tmp/bin"; mkdir -p "$fakebin"
cat >"$fakebin/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >>"$FAKE_MCP.log"
mkdir -p "$FAKE_MCP"
[ "$1" = mcp ] || exit 2
case "$2" in
  get) [ -f "$FAKE_MCP/$3" ] || { echo "No MCP server named \"$3\""; exit 1; }
       printf '%s:\n  Scope: User config\n  Type: stdio\n  Command: %s\n' "$3" "$(cat "$FAKE_MCP/$3")" ;;
  add) shift 2; [ "$1" = --scope ] && [ "$2" = user ] || { echo "scope must be user"; exit 3; }
       name="$3"; [ "$4" = -- ] || exit 4
       [ -f "$FAKE_MCP/$name" ] && { echo "already exists"; exit 1; }
       echo "$5" >"$FAKE_MCP/$name" ;;
  remove) shift 2; [ "$1" = --scope ] && shift 2; [ -f "$FAKE_MCP/$1" ] && rm "$FAKE_MCP/$1" || exit 1 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fakebin/claude"

fresh() { # new throwaway HOME
  export HOME="$tmp/home$1"; rm -rf "$HOME"; mkdir -p "$HOME/.claude"
  export CLAUDE_SKILLS_DIR="$HOME/.claude/skills" CLAUDE_CONFIG_HOME="$HOME/.claude"
  export CLAUDE_BIN="$fakebin/claude" FAKE_MCP="$HOME/fake-mcp" WORKAI_OS="${2:-Darwin}"
  S="$HOME/.claude/settings.json"; M="$HOME/.claude/workai-installed.json"
}
run() { "$here/install.sh" claude "$@" >"$tmp/out" 2>&1; }
backups() { ls "$HOME/.claude" | grep -c '^settings.json.workai-.*\.bak$'; }
wrapper="$here/claude/mcp/youtrack-mcp.sh"

# --- clean account (Mac) ---------------------------------------------------
fresh 1 Darwin
run --settings-only --check && bad "check fails on a clean account" || ok "check fails on a clean account"
grep -q '^missing  settings tui' "$tmp/out" && grep -q '^missing  mcp youtrack' "$tmp/out" && ok "check names the missing setting and MCP server" || bad "check names the missing setting and MCP server"
[ ! -e "$S" ] && [ ! -e "$FAKE_MCP/youtrack" ] && ok "check changes nothing" || bad "check changes nothing"

run --settings-only && ok "install exits 0" || bad "install exits 0"
[ "$(jq -r .tui "$S")" = fullscreen ] && [ "$(jq -r .skipWorkflowUsageWarning "$S")" = true ] && ok "tui and skipWorkflowUsageWarning set" || bad "tui and skipWorkflowUsageWarning set"
[ "$(jq -c .autoMode.soft_deny "$S")" = '["$defaults","Bash(tmutil delete:*)"]' ] && ok "Mac: tmutil soft_deny added, defaults kept" || bad "Mac: tmutil soft_deny added, defaults kept"
[ "$(cat "$FAKE_MCP/youtrack")" = "$wrapper" ] && ok "youtrack MCP registered at user scope with the wrapper" || bad "youtrack MCP registered at user scope with the wrapper"
[ "$(jq -c .mcp "$M")" = '["youtrack"]' ] && [ "$(jq '.settings.keys|length' "$M")" = 2 ] && ok "manifest records what was added" || bad "manifest records what was added"
[ "$(backups)" = 0 ] && ok "no backup when there was no settings file" || bad "no backup when there was no settings file"
[ ! -e "$CLAUDE_SKILLS_DIR" ] && ok "--settings-only links no skills" || bad "--settings-only links no skills"

snap="$(cat "$S" "$M"; ls -l "$HOME/.claude")"; calls="$(grep -c ' mcp add ' "$FAKE_MCP.log")"
run --settings-only && [ "$snap" = "$(cat "$S" "$M"; ls -l "$HOME/.claude")" ] && [ "$calls" = "$(grep -c ' mcp add ' "$FAKE_MCP.log")" ] \
  && ok "second install changes nothing" || bad "second install changes nothing"
run --settings-only --check && ok "check passes after install" || bad "check passes after install"
! grep -qi 'bearer\|token' "$FAKE_MCP.log" && ok "no token in any claude mcp call" || bad "no token in any claude mcp call"

run --settings-only --uninstall && ok "uninstall exits 0" || bad "uninstall exits 0"
[ "$(jq -c . "$S")" = '{}' ] && [ ! -e "$FAKE_MCP/youtrack" ] && [ ! -e "$M" ] && ok "uninstall removes settings, MCP server and manifest" || bad "uninstall removes settings, MCP server and manifest"

# --- existing settings (Mac) -----------------------------------------------
fresh 2 Darwin
cat >"$S" <<'EOF'
{
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]},
  "permissions": {"allow": ["Bash(ls:*)"]},
  "tui": "default",
  "autoMode": {"soft_deny": ["$defaults", "Bash(rm -rf:*)"], "environment": ["a Mac"]}
}
EOF
orig="$(jq -cS . "$S")"
mkdir -p "$FAKE_MCP"; echo "/somewhere/else/puppeteer" >"$FAKE_MCP/puppeteer"
run --settings-only && ok "install over existing settings exits 0" || bad "install over existing settings exits 0"
grep -q '^differs  settings tui: have "default"' "$tmp/out" && [ "$(jq -r .tui "$S")" = default ] && ok "differing value reported and left alone" || bad "differing value reported and left alone"
[ "$(jq -c .autoMode.soft_deny "$S")" = '["$defaults","Bash(rm -rf:*)","Bash(tmutil delete:*)"]' ] && ok "array unioned, nothing duplicated" || bad "array unioned, nothing duplicated"
[ "$(jq -cS '{hooks, permissions, env: .autoMode.environment}' "$S")" = "$(echo "$orig" | jq -cS '{hooks, permissions, env: .autoMode.environment}')" ] && ok "hooks, permissions, environment untouched" || bad "hooks, permissions, environment untouched"
[ "$(backups)" = 1 ] && [ "$(jq -cS . "$HOME"/.claude/settings.json.workai-*.bak)" = "$orig" ] && ok "one timestamped backup of the original" || bad "one timestamped backup of the original"
run --settings-only && [ "$(backups)" = 1 ] && ok "second run: no new backup" || bad "second run: no new backup"
[ "$(jq -c '.settings.keys | map(.path)' "$M")" = '[["skipWorkflowUsageWarning"]]' ] && ok "manifest does not claim the user's own tui" || bad "manifest does not claim the user's own tui"

jq '.skipWorkflowUsageWarning = false' "$S" >"$S.t" && mv "$S.t" "$S"
run --settings-only --uninstall && ok "uninstall exits 0" || bad "uninstall exits 0"
grep -q '^kept     settings skipWorkflowUsageWarning' "$tmp/out" && [ "$(jq .skipWorkflowUsageWarning "$S")" = false ] && ok "a value changed since install is kept" || bad "a value changed since install is kept"
[ "$(jq -cS 'del(.skipWorkflowUsageWarning)' "$S")" = "$orig" ] && ok "uninstall restores the rest exactly" || bad "uninstall restores the rest exactly"
[ -f "$FAKE_MCP/puppeteer" ] && [ ! -e "$FAKE_MCP/youtrack" ] && ok "other MCP servers untouched" || bad "other MCP servers untouched"

# --- MCP server registered by hand with another command ---------------------
fresh 3 Darwin
mkdir -p "$FAKE_MCP"; echo "/my/own/youtrack" >"$FAKE_MCP/youtrack"
run --settings-only && grep -q '^differs  mcp youtrack' "$tmp/out" && [ "$(cat "$FAKE_MCP/youtrack")" = /my/own/youtrack ] && ok "foreign youtrack registration left alone" || bad "foreign youtrack registration left alone"
[ "$(jq -c '.mcp // []' "$M")" = '[]' ] && ok "foreign registration not recorded" || bad "foreign registration not recorded"
run --settings-only --force && [ "$(cat "$FAKE_MCP/youtrack")" = /my/own/youtrack ] && ok "--force does not take over a registration it did not make" || bad "--force does not take over a registration it did not make"
run --settings-only --uninstall && [ "$(cat "$FAKE_MCP/youtrack")" = /my/own/youtrack ] && ok "uninstall leaves it too" || bad "uninstall leaves it too"

# --- Linux, broken settings, missing claude ----------------------------------
fresh 4 Linux
run --settings-only && [ "$(jq -c 'has("autoMode")' "$S")" = false ] && ok "Linux: no Mac-only soft_deny" || bad "Linux: no Mac-only soft_deny"

fresh 5 Darwin
echo '{"tui": ' >"$S"
run --settings-only && bad "invalid settings.json refused" || ok "invalid settings.json refused"
[ "$(cat "$S")" = '{"tui": ' ] && [ "$(backups)" = 0 ] && ok "invalid settings.json left untouched" || bad "invalid settings.json left untouched"

fresh 6 Darwin
CLAUDE_BIN="$tmp/nope" run --settings-only && bad "missing claude CLI is a problem" || ok "missing claude CLI is a problem"
[ "$(jq -r .tui "$S")" = fullscreen ] && ok "settings still merged without the claude CLI" || bad "settings still merged without the claude CLI"

# --- full install (skills + settings + MCP) and --skills-only ----------------
fresh 7 Darwin
run --skills-only && [ -L "$CLAUDE_SKILLS_DIR/workai-backlog" ] && [ ! -e "$S" ] && [ ! -e "$FAKE_MCP/youtrack" ] && ok "--skills-only touches only skills" || bad "--skills-only touches only skills"
run && [ -f "$S" ] && [ -f "$FAKE_MCP/youtrack" ] && ok "plain install does all three" || bad "plain install does all three"
run --uninstall && [ ! -e "$CLAUDE_SKILLS_DIR/workai-backlog" ] && [ ! -e "$FAKE_MCP/youtrack" ] && [ ! -e "$M" ] && ok "plain uninstall undoes all three" || bad "plain uninstall undoes all three"

# --- the YouTrack wrapper ---------------------------------------------------
wb="$tmp/wbin"; mkdir -p "$wb"
printf '#!/bin/sh\necho s3cr3t-tok\n' >"$wb/security"
cat >"$wb/npx" <<'EOF'
#!/bin/sh
echo "ARGS: $*"
echo "ENV: $YOUTRACK_MCP_AUTH"
EOF
chmod +x "$wb/security" "$wb/npx"
export WORKAI_SECRET_BACKEND=keychain  # the fake security above, also on Linux
unset XDG_CONFIG_HOME  # the token-file cases below use $HOME/.config (CI runners set XDG_CONFIG_HOME)
PATH="$wb:/usr/bin:/bin" "$wrapper" >"$tmp/out" 2>&1
grep -q '^ARGS: -y mcp-remote@[0-9][0-9.]* http://127.0.0.1:8645/mcp --transport http-only --allow-http --header Authorization:\${YOUTRACK_MCP_AUTH}$' "$tmp/out" \
  && ok "wrapper runs a pinned mcp-remote with a placeholder header" || bad "wrapper runs a pinned mcp-remote with a placeholder header"
! grep -q '^ARGS: .*s3cr3t' "$tmp/out" && grep -q '^ENV: Bearer s3cr3t-tok$' "$tmp/out" && ok "token only in the environment, not the arguments" || bad "token only in the environment, not the arguments"
printf '#!/bin/sh\nexit 44\n' >"$wb/security"
HOME="$tmp/nohome" PATH="$wb:/usr/bin:/bin" "$wrapper" >"$tmp/out" 2>&1 && bad "wrapper fails without a token" || ok "wrapper fails without a token"
mkdir -p "$tmp/nohome/.config/workai"; echo filetok >"$tmp/nohome/.config/workai/youtrack-token"; chmod 644 "$tmp/nohome/.config/workai/youtrack-token"
HOME="$tmp/nohome" PATH="$wb:/usr/bin:/bin" "$wrapper" >"$tmp/out" 2>&1 && bad "wrapper refuses a world-readable token file" || ok "wrapper refuses a world-readable token file"
chmod 600 "$tmp/nohome/.config/workai/youtrack-token"
HOME="$tmp/nohome" PATH="$wb:/usr/bin:/bin" "$wrapper" >"$tmp/out" 2>&1 && grep -q '^ENV: Bearer filetok$' "$tmp/out" && ok "wrapper reads a mode-600 token file" || bad "wrapper reads a mode-600 token file"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
