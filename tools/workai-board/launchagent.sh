#!/usr/bin/env bash
# Run `workai-board --web` as a macOS LaunchAgent: starts at login, restarts
# if it dies (RunAtLoad + KeepAlive). Mac only. 127.0.0.1 only, like --web.
#
#   launchagent.sh install [--port N] [--allow-worktree]   write the plist, (re)load it
#   launchagent.sh uninstall                               unload it, remove the plist (logs kept)
#   launchagent.sh status                                  loaded? pid? exit 3 when not installed
#   launchagent.sh plist [--port N]                        print the plist, change nothing
#
# The plist runs this checkout's tools/workai-board/.venv/bin/python, so
# install from the main checkout (repos/workai-playbooks), never from a card
# worktree that will be removed (refused unless --allow-worktree).
#
# Env: WORKAI_OS (default uname -s), WORKAI_LAUNCHAGENTS_DIR (default
# ~/Library/LaunchAgents), WORKAI_LOG_DIR (default ~/Library/Logs).
# launchctl is taken from PATH (tests put a fake one first).
set -euo pipefail

LABEL="com.bartek.workai-board-web"
board_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python="$board_dir/.venv/bin/python"
agents_dir="${WORKAI_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
log_dir="${WORKAI_LOG_DIR:-$HOME/Library/Logs}"
plist_path="$agents_dir/$LABEL.plist"
log_path="$log_dir/workai-board-web.log"
domain="gui/$(id -u)"

die() { echo "launchagent.sh: $*" >&2; exit 2; }
usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

os="$(echo "${WORKAI_OS:-$(uname -s)}" | tr 'A-Z' 'a-z')"

cmd="${1:-}"; [ $# -gt 0 ] && shift
port=8646; allow_worktree=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) [ $# -ge 2 ] || die "--port needs a number"; port="$2"; shift 2 ;;
    --port=*) port="${1#--port=}"; shift ;;
    --allow-worktree) allow_worktree=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$port" in ''|*[!0-9]*) die "--port must be a number, got '$port'" ;; esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "--port out of range: $port"

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by workai-playbooks tools/workai-board/launchagent.sh; do not edit by hand. -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml "$python")</string>
        <string>-m</string>
        <string>workai_board</string>
        <string>--web</string>
        <string>--port</string>
        <string>$port</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xml "$board_dir")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$(xml "$log_path")</string>
    <key>StandardErrorPath</key>
    <string>$(xml "$log_path")</string>
</dict>
</plist>
EOF
}

mac_only() { [ "$os" = darwin ] || die "Mac only (this is '$os'); a systemd user unit would be its own card"; }
loaded() { launchctl print "$domain/$LABEL" >/dev/null 2>&1; }

is_worktree() {
  local gd cd
  gd="$(git -C "$board_dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cd="$(cd "$board_dir" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
  [ "$(cd "$gd" && pwd -P)" != "$cd" ]
}

case "$cmd" in
  plist)
    plist ;;
  install)
    mac_only
    [ -x "$python" ] || die "no $python; run 'uv sync' in $board_dir first"
    if is_worktree && [ "$allow_worktree" = 0 ]; then
      die "$board_dir is a git worktree; install from the main checkout (or pass --allow-worktree)"
    fi
    mkdir -p "$agents_dir" "$log_dir"
    new="$(mktemp "$agents_dir/.$LABEL.XXXXXX")"
    plist >"$new"
    if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$new" >/dev/null; then
      rm -f "$new"; die "generated plist does not lint"
    fi
    if [ -f "$plist_path" ] && cmp -s "$new" "$plist_path" && loaded; then
      rm -f "$new"
      echo "$LABEL already installed and loaded (port $port): nothing to do"
      exit 0
    fi
    if loaded; then launchctl bootout "$domain/$LABEL" || true; fi
    mv "$new" "$plist_path"
    launchctl bootstrap "$domain" "$plist_path"
    echo "installed $LABEL: http://127.0.0.1:$port/"
    echo "  plist: $plist_path"
    echo "  log:   $log_path"
    ;;
  uninstall)
    mac_only
    if loaded; then launchctl bootout "$domain/$LABEL"; echo "unloaded $LABEL"; fi
    if [ -f "$plist_path" ]; then rm -f "$plist_path"; echo "removed $plist_path"; fi
    echo "$LABEL not installed (log kept: $log_path)"
    ;;
  status)
    mac_only
    if [ ! -f "$plist_path" ]; then echo "$LABEL: not installed"; exit 3; fi
    if out="$(launchctl print "$domain/$LABEL" 2>/dev/null)"; then
      pid="$(printf '%s\n' "$out" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
      if [ -n "$pid" ]; then echo "$LABEL: loaded, pid $pid"; else echo "$LABEL: loaded, not running"; fi
    else
      echo "$LABEL: plist present but not loaded ($plist_path)"; exit 3
    fi
    echo "  log: $log_path"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
