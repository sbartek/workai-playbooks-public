#!/usr/bin/env bash
# The shared-file lock for ~/workai, as one command per step, so a session
# that allows only `bash` (no mkdir, no chained commands) can still use it.
#
#   bash lock.sh take OWNER [TIMEOUT_SECONDS]   wait for the lock (default 600 s)
#   bash lock.sh release OWNER                  release it (only its owner can)
#   bash lock.sh status                         who holds it, since when, alive?
#
# The lock is the directory $WORKAI_ROOT/.workai.lock (default ~/workai) with
# an `owner` file of key=value lines: since (epoch seconds), pid, host,
# session, owner (the rest of the line, spaces allowed). OWNER may contain
# spaces. Exit 0 on success, 1 on timeout or a release by someone else,
# 2 on bad usage.
#
# pid is the long-lived process that holds the lock: $LOCK_PID if set, else
# Claude Code's $CLAUDE_PID, else the calling shell ($PPID). A script that
# takes the lock for longer than its own shell should set LOCK_PID.
# session is $CLAUDE_CODE_SESSION_ID, else $TMUX_PANE, else "-".
#
# `take` breaks a lock by itself only when its owner is provably gone:
#   - the recorded pid is not running on this same host, or
#   - there is no owner file and the lock directory is over a minute old
#     (a take killed between mkdir and writing the owner).
# Anything else (live pid, another host, old-format owner) is left alone.
set -u
root="${WORKAI_ROOT:-$HOME/workai}"
lock="$root/.workai.lock"
host="$(hostname -s 2>/dev/null || hostname)"

field() { # KEY: value from the owner file, empty if missing
  [ -f "$lock/owner" ] || return 0
  sed -n "s/^$1=//p" "$lock/owner" 2>/dev/null | head -1
}
who() {
  local o; o="$(field owner)"
  if [ -n "$o" ]; then echo "$o"
  elif [ -f "$lock/owner" ]; then sed -n '1s/ [0-9]*$//p' "$lock/owner"  # old format "<owner> <epoch>"
  else echo "(no owner file)"; fi
}
age() { local s; s="$(field since)"; case "$s" in ''|*[!0-9]*) echo "?";; *) echo $(( $(date +%s) - s ));; esac; }
alive() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

# Why the current lock may be broken, or nothing if it must be respected.
breakable() {
  [ -d "$lock" ] || return 1
  if [ ! -f "$lock/owner" ]; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && { echo "no owner file for over a minute"; return 0; }
    return 1
  fi
  local pid h; pid="$(field pid)"; h="$(field host)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$h" = "$host" ] || return 1
  alive "$pid" && return 1
  echo "owner process $pid is gone"
}

break_lock() { # move the stale lock aside atomically, then delete it
  local before reason aside
  reason="$1"; before="$(cat "$lock/owner" 2>/dev/null)"
  aside="$lock.stale.$$"
  mv "$lock" "$aside" 2>/dev/null || return 1   # someone else got there first
  if [ "$(cat "$aside/owner" 2>/dev/null)" != "$before" ] && [ ! -e "$lock" ]; then
    mv "$aside" "$lock" 2>/dev/null; return 1      # it changed under us: put it back
  fi
  echo "broke a stale lock ($reason): $(sed -n 's/^owner=//p' "$aside/owner" 2>/dev/null)" >&2
  rm -rf "$aside"
}

case "${1:-}" in
  take)
    owner="${2:-}"; timeout="${3:-600}"
    [ -n "$owner" ] || { echo "usage: lock.sh take OWNER [TIMEOUT_SECONDS]" >&2; exit 2; }
    case "$owner" in *$'\n'*) echo "owner must be one line" >&2; exit 2 ;; esac
    case "$timeout" in ''|*[!0-9]*) echo "timeout must be whole seconds: $timeout" >&2; exit 2 ;; esac
    mkdir -p "$root"
    waited=0
    until mkdir "$lock" 2>/dev/null; do
      if reason="$(breakable)" && break_lock "$reason"; then continue; fi
      if [ "$waited" -ge "$timeout" ]; then
        echo "lock busy after ${waited}s: held by $(who) for $(age)s, pid $(field pid) on $(field host) ($lock)" >&2
        echo "if that owner is really gone (another host, old format), remove it by hand: rm -r $lock" >&2
        exit 1
      fi
      sleep 5; waited=$((waited + 5))
    done
    tmpf="$lock/owner.tmp.$$"
    printf 'since=%s\npid=%s\nhost=%s\nsession=%s\nowner=%s\n' "$(date +%s)" \
      "${LOCK_PID:-${CLAUDE_PID:-$PPID}}" "$host" "${CLAUDE_CODE_SESSION_ID:-${TMUX_PANE:--}}" "$owner" >"$tmpf"
    mv "$tmpf" "$lock/owner"
    echo "lock taken by $owner"
    ;;
  release)
    owner="${2:-}"
    [ -n "$owner" ] || { echo "usage: lock.sh release OWNER" >&2; exit 2; }
    [ -d "$lock" ] || { echo "no lock held"; exit 0; }
    current="$(who)"
    [ "$current" = "$owner" ] || { echo "lock held by $current, not $owner: not released" >&2; exit 1; }
    rm -f "$lock/owner" "$lock"/owner.tmp.* && rmdir "$lock" || { echo "could not remove $lock" >&2; exit 1; }
    echo "lock released by $owner"
    ;;
  status)
    if [ -d "$lock" ]; then
      pid="$(field pid)"; state=""
      if [ -n "$pid" ]; then
        if [ "$(field host)" != "$host" ]; then state=" (on $(field host))"
        elif alive "$pid"; then state=" (alive)"; else state=" (gone: the next take breaks it)"; fi
      fi
      echo "held by $(who) for $(age)s, pid ${pid:-?}$state, session $(field session)"
      reason="$(breakable)" && [ -z "$pid" ] && echo "stale: $reason; the next take breaks it"
    else
      echo "free"
    fi
    ;;
  *) echo "usage: lock.sh take OWNER [TIMEOUT] | release OWNER | status" >&2; exit 2 ;;
esac
exit 0
