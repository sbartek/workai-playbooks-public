#!/usr/bin/env bash
# Tests for the workai-board skill (skills/workai-board/board.sh) on a private
# tmux server and a throwaway workai: never touches the real board session.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
board_sh="$here/skills/workai-board/board.sh"
tmp="$(mktemp -d)"
export WORKAI_BOARD_TMUX_SOCKET="workai-board-test-$$"
cleanup() { tmux -L "$WORKAI_BOARD_TMUX_SOCKET" kill-server 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -f "$tmp/out" ] && sed 's/^/     /' "$tmp/out" | head -20; fails=$((fails + 1)); }

py="$here/tools/workai-board/.venv/bin/python"
if ! command -v tmux >/dev/null 2>&1 || ! "$py" -c 'import textual' 2>/dev/null; then
  echo "SKIP: needs tmux and tools/workai-board/.venv (uv sync there)"; echo "all tests pass"; exit 0
fi
export WORKAI_BOARD_CMD="$py -m workai_board" PYTHONPATH="$here/tools/workai-board/src"
root="$tmp/workai"; c="$root/projects/01-demo/backlog/todo"; mkdir -p "$c" "$root/archives"
printf -- '---\nid: 001\ntitle: "Paint the fence"\nrepo: hub\npriority: 2\ndepends: []\nclaimed_by:\nworktree:\nbranch:\nstarted:\nwaiting:\nfinished:\n---\n## Goal\nG\n## Done when\nD\n## Notes\n' >"$c/001-paint-the-fence.md"
sessions() { tmux -L "$WORKAI_BOARD_TMUX_SOCKET" list-sessions -F '#S' 2>/dev/null | grep -c . ; }

bash "$board_sh" status >"$tmp/out" 2>&1; [ $? = 3 ] && ok "status: not running is exit 3" || bad "status: not running is exit 3"
bash "$board_sh" show >"$tmp/out" 2>&1; [ $? = 3 ] && ok "show: not running is exit 3" || bad "show: not running is exit 3"
bash "$board_sh" start --root "$root" >"$tmp/out" 2>&1 && grep -q 'attach -t workai-board' "$tmp/out" && [ "$(sessions)" = 1 ] \
  && ok "start: one session and the attach hint" || bad "start: one session and the attach hint"
bash "$board_sh" start --root "$root" >"$tmp/out" 2>&1 && grep -q 'already running' "$tmp/out" && [ "$(sessions)" = 1 ] \
  && ok "start again reuses it (still one)" || bad "start again reuses it (still one)"
seen=0; for _ in $(seq 1 40); do bash "$board_sh" show >"$tmp/out" 2>&1; grep -q '01-001 Paint the fence' "$tmp/out" && { seen=1; break; }; sleep 0.25; done
[ "$seen" = 1 ] && grep -q 'todo (1)' "$tmp/out" && ok "show prints the board's screen" || bad "show prints the board's screen"
pid1="$(tmux -L "$WORKAI_BOARD_TMUX_SOCKET" list-panes -t '=workai-board:' -F '#{pane_pid}')"
bash "$board_sh" restart --root "$root" >"$tmp/out" 2>&1
pid2="$(tmux -L "$WORKAI_BOARD_TMUX_SOCKET" list-panes -t '=workai-board:' -F '#{pane_pid}' 2>/dev/null)"
[ "$(sessions)" = 1 ] && [ -n "$pid2" ] && [ "$pid1" != "$pid2" ] && ok "restart: a new board, still one session" || bad "restart: a new board, still one session"
tmux -L "$WORKAI_BOARD_TMUX_SOCKET" new-session -d -s workai-board-other sleep 60
bash "$board_sh" stop >"$tmp/out" 2>&1 && ! tmux -L "$WORKAI_BOARD_TMUX_SOCKET" has-session -t '=workai-board' 2>/dev/null \
  && tmux -L "$WORKAI_BOARD_TMUX_SOCKET" has-session -t '=workai-board-other' 2>/dev/null \
  && ok "stop ends only the session named exactly workai-board" || bad "stop ends only the session named exactly workai-board"
bash "$board_sh" stop >"$tmp/out" 2>&1 && grep -q 'not running' "$tmp/out" && ok "stop when stopped is harmless" || bad "stop when stopped is harmless"
bash "$board_sh" bogus >"$tmp/out" 2>&1; [ $? = 2 ] && ok "unknown command is a usage error" || bad "unknown command is a usage error"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
