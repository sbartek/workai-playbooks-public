"""`workai-board --tmux`: run the board in a detached tmux session to attach to.

The session is only a host: attach from any terminal tab with
`tmux attach -t workai-board`, detach with Ctrl-b d, and the board keeps
running and refreshing. Works without a ~/.tmux.conf; the board is started
with a 256-colour TERM if the pane's TERM is not one already.
"""
from __future__ import annotations

import shlex
import shutil
import subprocess
import sys
from pathlib import Path

SESSION = "workai-board"
CANDIDATES = ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux")


class TmuxError(RuntimeError):
    pass


def find_tmux() -> str:
    found = shutil.which("tmux") or next((c for c in CANDIDATES if Path(c).is_file()), None)
    if not found:
        raise TmuxError("tmux not found; install it (brew install tmux / apt install tmux)")
    return found


def base(tmux: str, socket: str | None) -> list[str]:
    return [tmux] + (["-L", socket] if socket else [])


def attach_hint(socket: str | None) -> str:
    return "tmux " + (f"-L {socket} " if socket else "") + f"attach -t {SESSION}"


def board_command(root: Path, report: Path, archives: bool) -> str:
    """Shell command for the pane: force a 256-colour TERM, then exec the board."""
    args = [sys.executable, "-m", "workai_board", "--root", str(root), "--report", str(report)]
    if archives:
        args.append("--archives")
    return ('case "$TERM" in *256color*) ;; *) TERM=xterm-256color; export TERM;; esac; exec '
            + shlex.join(args))


def session_exists(tmux: str, socket: str | None) -> bool:
    r = subprocess.run(base(tmux, socket) + ["has-session", "-t", f"={SESSION}"], capture_output=True)
    return r.returncode == 0


def start(root: Path, report: Path, archives: bool = False, socket: str | None = None) -> tuple[bool, str]:
    """Start the session if missing. Returns (started, message)."""
    tmux = find_tmux()
    root, report = Path(root).expanduser().resolve(), Path(report).expanduser().resolve()
    if session_exists(tmux, socket):
        return False, f"workai-board is already running in tmux session '{SESSION}'.\nAttach with: {attach_hint(socket)}"
    cmd = base(tmux, socket) + ["new-session", "-d", "-s", SESSION, "-x", "200", "-y", "50",
                                "sh", "-c", board_command(root, report, archives)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise TmuxError(f"tmux new-session failed: {(r.stderr or r.stdout).strip()}")
    return True, (f"Started workai-board in tmux session '{SESSION}' (detached).\n"
                  f"Attach with: {attach_hint(socket)}   (detach: Ctrl-b d; it keeps running)")
