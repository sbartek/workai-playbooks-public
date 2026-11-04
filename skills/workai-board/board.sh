#!/usr/bin/env bash
# Run workai-board for the user in the tmux session "workai-board".
#
#   board.sh start [BOARD ARGS...]    start it unless running (reuses it)
#   board.sh restart [BOARD ARGS...]  stop + start (after a code change)
#   board.sh stop                     stop it
#   board.sh status                   running or not, and how to attach
#   board.sh show                     print what the board shows now
#
# BOARD ARGS go to workai-board (e.g. --archives, --root DIR). The board
# command is, in order: $WORKAI_BOARD_CMD, `workai-board` on PATH (installed),
# the repo's tools/workai-board/.venv, `uv run` in tools/workai-board.
# WORKAI_BOARD_TMUX_SOCKET=NAME uses a private tmux server (tmux -L NAME):
# tests and evals must set it so they never touch the user's real session.
# Only the session named exactly "workai-board" is ever stopped.
set -u
SESSION=workai-board
here="$(cd "$(dirname "$0")" && pwd -P)"       # real folder: the symlink resolved
tools="$(cd "$here/../../tools/workai-board" 2>/dev/null && pwd -P)" || tools=""
socket="${WORKAI_BOARD_TMUX_SOCKET:-}"

tmux_bin="$(command -v tmux || true)"
for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /usr/bin/tmux; do
  [ -n "$tmux_bin" ] && break; [ -x "$c" ] && tmux_bin="$c"
done
[ -n "$tmux_bin" ] || { echo "tmux not found; install it (brew install tmux / apt install tmux)" >&2; exit 1; }
t() { if [ -n "$socket" ]; then "$tmux_bin" -L "$socket" "$@"; else "$tmux_bin" "$@"; fi; }
attach="tmux ${socket:+-L $socket }attach -t $SESSION"
running() { t has-session -t "=$SESSION" 2>/dev/null; }

board() { # run the board command with the given arguments
  if [ -n "${WORKAI_BOARD_CMD:-}" ]; then
    # shellcheck disable=SC2086
    $WORKAI_BOARD_CMD "$@"
  elif command -v workai-board >/dev/null 2>&1; then
    workai-board "$@"
  elif [ -n "$tools" ] && [ -x "$tools/.venv/bin/python" ]; then
    "$tools/.venv/bin/python" -m workai_board "$@"
  elif [ -n "$tools" ] && command -v uv >/dev/null 2>&1; then
    uv run --project "$tools" workai-board "$@"
  else
    echo "workai-board not found: install it, or run 'uv sync' in tools/workai-board of workai-playbooks" >&2
    return 1
  fi
}

start() {
  if running; then
    echo "workai-board is already running (tmux session '$SESSION'); reused, not started twice."
    echo "Attach with: $attach   (detach: Ctrl-b d)"
    return 0
  fi
  board --tmux ${socket:+--tmux-socket "$socket"} "$@" || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10; do running && return 0; sleep 0.3; done
  echo "the tmux session did not come up; run the board without --tmux to see the error" >&2
  return 1
}

stop() {
  if running; then t kill-session -t "=$SESSION" && echo "workai-board stopped"
  else echo "workai-board is not running"; fi
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  start) start "$@" ;;
  restart) stop; start "$@" ;;
  stop) stop ;;
  status)
    if running; then echo "running in tmux session '$SESSION'. Attach with: $attach"
    else echo "not running (start: bash $here/board.sh start)"; exit 3; fi ;;
  show)
    running || { echo "workai-board is not running" >&2; exit 3; }
    t capture-pane -p -J -t "=$SESSION:" ;;
  *) sed -n '4,8p' "$0" | sed 's/^# *//' >&2; exit 2 ;;
esac
