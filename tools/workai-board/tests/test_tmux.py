"""`workai-board --tmux`: a detached session on a private tmux server (never the user's)."""
from __future__ import annotations

import os
import subprocess
import sys
import time
import uuid

import pytest
from conftest import REPORT, snapshot

from workai_board import tmux

try:
    TMUX = tmux.find_tmux()
except tmux.TmuxError:
    TMUX = None

pytestmark = pytest.mark.skipif(TMUX is None, reason="tmux not installed")


@pytest.fixture
def socket():
    name = f"workai-board-test-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    yield name
    subprocess.run([TMUX, "-L", name, "kill-server"], capture_output=True)
    sock_dir = os.environ.get("TMUX_TMPDIR") or "/tmp"
    sock = os.path.join(sock_dir, f"tmux-{os.getuid()}", name)
    if os.path.exists(sock):
        os.remove(sock)


def run_cli(workai, socket, term="screen"):
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "COLORTERM")}
    env["TERM"] = term
    return subprocess.run([sys.executable, "-m", "workai_board", "--tmux", "--tmux-socket", socket,
                           "--root", str(workai), "--report", str(REPORT)],
                          capture_output=True, text=True, env=env, timeout=30)


def t(socket, *args):
    return subprocess.run([TMUX, "-L", socket, *args], capture_output=True, text=True).stdout


def wait_for(socket, needle, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        screen = t(socket, "capture-pane", "-p", "-e", "-t", "=workai-board:")
        if needle in screen:
            return screen
        time.sleep(0.2)
    raise AssertionError(f"{needle!r} never appeared; last screen:\n{screen}")


def test_tmux_session_started_once_and_reused(workai, socket):
    before = snapshot(workai)
    r = run_cli(workai, socket)
    assert r.returncode == 0, r.stderr
    assert "Started workai-board in tmux session 'workai-board'" in r.stdout
    assert f"tmux -L {socket} attach -t workai-board" in r.stdout

    panes = t(socket, "list-panes", "-s", "-t", "=workai-board", "-F", "#{pane_pid}|#{pane_dead}|#{pane_start_command}")
    lines = panes.strip().splitlines()
    assert len(lines) == 1
    pid, dead, start = lines[0].split("|", 2)
    assert dead == "0" and "workai_board" in start and str(workai) in start

    screen = wait_for(socket, "todo (5)")
    assert "doing (2)" in screen and "waiting (1)" in screen and "done (3)" in screen
    # Colour survives even though the launching TERM was plain "screen": the
    # active column header is xterm colour 62, sent as 256-colour or (tmux sets
    # COLORTERM=truecolor in panes) as RGB, which tmux maps for the outer terminal.
    assert "48;5;62" in screen or "48;2;95;95;215" in screen

    r2 = run_cli(workai, socket)
    assert r2.returncode == 0
    assert "already running" in r2.stdout and "attach -t workai-board" in r2.stdout
    assert t(socket, "list-sessions", "-F", "#{session_name}").split() == ["workai-board"]
    assert t(socket, "list-panes", "-s", "-t", "=workai-board", "-F", "#{pane_pid}").strip() == pid

    t(socket, "kill-session", "-t", "=workai-board")
    assert snapshot(workai) == before


def test_board_command_forces_256_colours(tmp_path):
    cmd = tmux.board_command(tmp_path / "w x", tmp_path / "report.py", archives=True)
    assert cmd.startswith('case "$TERM" in *256color*) ;; *) TERM=xterm-256color')
    assert f"--root '{tmp_path / 'w x'}'" in cmd and cmd.endswith("--archives")
    out = subprocess.run(["sh", "-c", cmd.replace("exec ", "echo $TERM; : ", 1)],
                         env={"TERM": "screen", "PATH": os.environ["PATH"]}, capture_output=True, text=True)
    assert out.stdout.split()[0] == "xterm-256color"
    out = subprocess.run(["sh", "-c", cmd.replace("exec ", "echo $TERM; : ", 1)],
                         env={"TERM": "tmux-256color", "PATH": os.environ["PATH"]}, capture_output=True, text=True)
    assert out.stdout.split()[0] == "tmux-256color"
