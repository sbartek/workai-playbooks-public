#!/usr/bin/env bash
# Tests for the shared-file lock helper (skills/workai-migrate/lock.sh).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
lock_sh="$here/skills/workai-migrate/lock.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export WORKAI_ROOT="$tmp/workai"
mkdir -p "$WORKAI_ROOT"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

[ "$(bash "$lock_sh" status)" = "free" ] && ok "free at start" || bad "free at start"
bash "$lock_sh" take agent-a >/dev/null && [ -d "$WORKAI_ROOT/.workai.lock" ] && ok "take creates the lock" || bad "take creates the lock"
grep -qx 'owner=agent-a' "$WORKAI_ROOT/.workai.lock/owner" && grep -q '^since=[0-9]' "$WORKAI_ROOT/.workai.lock/owner" && ok "owner file names the owner" || bad "owner file names the owner"
bash "$lock_sh" status | grep -q '^held by agent-a' && ok "status shows the holder" || bad "status shows the holder"
bash "$lock_sh" take agent-b 0 2>"$tmp/err" >/dev/null; rc=$?
[ "$rc" = 1 ] && grep -q 'held by agent-a' "$tmp/err" && ok "busy lock times out with the holder named" || bad "busy lock times out with the holder named"
bash "$lock_sh" release agent-b 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ -d "$WORKAI_ROOT/.workai.lock" ] && ok "only the owner can release" || bad "only the owner can release"
bash "$lock_sh" release agent-a >/dev/null && [ ! -e "$WORKAI_ROOT/.workai.lock" ] && ok "owner releases" || bad "owner releases"
bash "$lock_sh" release agent-a >/dev/null && ok "release when free is harmless" || bad "release when free is harmless"
bash "$lock_sh" take 2>/dev/null; [ $? = 2 ] && ok "take without owner is a usage error" || bad "take without owner is a usage error"

L="$WORKAI_ROOT/.workai.lock"
host="$(hostname -s 2>/dev/null || hostname)"
dead_pid() { sleep 0 & local p=$!; wait "$p"; echo "$p"; }

# owner names with spaces
bash "$lock_sh" take "agent B card 114" >/dev/null && bash "$lock_sh" status | grep -q '^held by agent B card 114 for' && ok "owner with spaces: take + status" || bad "owner with spaces: take + status"
bash "$lock_sh" release "agent B" 2>/dev/null && bad "a prefix of the owner cannot release" || ok "a prefix of the owner cannot release"
bash "$lock_sh" release "agent B card 114" >/dev/null && [ ! -e "$L" ] && ok "owner with spaces releases" || bad "owner with spaces releases"

# the owner file records pid and session
LOCK_PID=$$ CLAUDE_CODE_SESSION_ID=sess-test bash "$lock_sh" take agent-p >/dev/null
grep -qx "pid=$$" "$L/owner" && grep -qx 'session=sess-test' "$L/owner" && grep -qx "host=$host" "$L/owner" && ok "owner file records pid, host and session" || bad "owner file records pid, host and session"
bash "$lock_sh" status | grep -q '(alive)' && ok "status says the owner is alive" || bad "status says the owner is alive"
bash "$lock_sh" take agent-q 0 2>/dev/null && bad "a live owner is never broken" || ok "a live owner is never broken"
bash "$lock_sh" release agent-p >/dev/null

# a dead owner on this host is broken automatically
mkdir "$L" && printf 'since=1\npid=%s\nhost=%s\nsession=x\nowner=crashed agent\n' "$(dead_pid)" "$host" >"$L/owner"
bash "$lock_sh" status | grep -q 'gone' && ok "status says a dead owner is gone" || bad "status says a dead owner is gone"
bash "$lock_sh" take agent-r 0 >/dev/null 2>"$tmp/err" && grep -qx 'owner=agent-r' "$L/owner" && grep -q 'broke a stale lock' "$tmp/err" && ok "dead-PID owner is broken by take" || bad "dead-PID owner is broken by take"
bash "$lock_sh" release agent-r >/dev/null

# a dead pid on ANOTHER host is not ours to judge
mkdir "$L" && printf 'since=1\npid=%s\nhost=other-host\nsession=x\nowner=remote agent\n' "$(dead_pid)" >"$L/owner"
bash "$lock_sh" take agent-s 0 2>/dev/null && bad "another host's lock is left alone" || ok "another host's lock is left alone"
rm -r "$L"

# a take killed between mkdir and the owner file: broken after a minute, not before
mkdir "$L"
bash "$lock_sh" status | grep -q '^held by (no owner file)' && ok "status without an owner file does not crash" || bad "status without an owner file does not crash"
bash "$lock_sh" take agent-t 0 2>/dev/null && bad "a fresh lock without owner is respected" || ok "a fresh lock without owner is respected"
touch -t 202601010000 "$L"
bash "$lock_sh" take agent-t 0 >/dev/null 2>&1 && grep -qx 'owner=agent-t' "$L/owner" && ok "an old lock without owner is broken" || bad "an old lock without owner is broken"
bash "$lock_sh" release agent-t >/dev/null

# the old one-line format still releases
mkdir "$L" && echo "old agent 1700000000" >"$L/owner"
bash "$lock_sh" status | grep -q '^held by old agent for' && bash "$lock_sh" release "old agent" >/dev/null && [ ! -e "$L" ] && ok "old owner format: status + release" || bad "old owner format: status + release"

[ "$fails" = 0 ] && echo "all tests pass" || { echo "$fails failed"; exit 1; }
