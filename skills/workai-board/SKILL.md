---
name: workai-board
description: Run the workai-board terminal board for the user in the tmux session "workai-board" - start it (reusing a running one, never a second), say how to attach, restart it after a code change, stop it, and answer "what does the board say" / "what's on the board" from a capture of its screen. Use when the user says "start the board", "show the board", "restart the board", "stop the board" or asks what the board shows.
---

# workai-board session

The board (`tools/workai-board` in workai-playbooks) is a read-only Textual
view of every hub's backlog. It runs in a detached tmux session named
`workai-board`; the user attaches from any terminal tab. Everything goes
through [board.sh](board.sh) next to this file. Run each command alone,
nothing chained.

## Start ("start the board", "show me the board")

```
bash <this skill's folder>/board.sh start
```

If the session is already running it is reused and nothing new starts, so
there is only ever one. Extra arguments go to the board: `--archives` also
shows archived hubs. Tell the user how to attach, exactly as printed:
`tmux attach -t workai-board` (detach with Ctrl-b d; the board keeps
running). Inside tmux already, `tmux switch-client -t workai-board` instead.

## What's on the board

```
bash <this skill's folder>/board.sh show
```

prints the screen as text: the columns (todo, next, doing, waiting, done, parked)
sit side by side, each about 40 characters wide, with a count in the header
and one box per card (`NN-NNN title`, then its state line). If the session
was last sized by a terminal under 100 columns (a phone), the board is in
narrow mode and shows one column only, header `< doing (2) >`: say so, and
use the report for the other columns. Read it column
by column and answer in a few lines: what is in Next, what is in progress
and by whom, what is waiting on the user. Say it is a snapshot of the
visible part (long columns are cut at the bottom). For exact data, or when
the board is not running, use the workai-open-project report
(`report.py --json --all` / `--waiting`) instead of starting the board.

## Restart, stop, status

```
bash <this skill's folder>/board.sh restart    # after merging board code
bash <this skill's folder>/board.sh stop
bash <this skill's folder>/board.sh status     # exit 3 when not running
```

`stop` and `restart` touch only the session named exactly `workai-board`,
never another tmux session. Restart after a change to `tools/workai-board`
so the board runs the new code.

## Which board command runs

In order: `$WORKAI_BOARD_CMD`, `workai-board` on PATH (installed), the
repo's `tools/workai-board/.venv`, then `uv run` in `tools/workai-board`
(creates the venv on first use). If none works, say so and suggest
`uv sync` in `tools/workai-board`.

Tests and evals set `WORKAI_BOARD_TMUX_SOCKET=<name>` so they run on a
private tmux server and never touch the user's real board.

## The web view is not this session

`workai-board --web` (the read-only page on http://127.0.0.1:8646/, which
`tailscale serve` shows on the phone) is not run by board.sh: on the Mac it
is the LaunchAgent `com.bartek.workai-board-web`, started at login and
restarted by launchd. Check it with `tools/workai-board/launchagent.sh
status` in the repo's main checkout; restart it after a board code change
with `launchctl kickstart -k gui/$(id -u)/com.bartek.workai-board-web`; log
in `~/Library/Logs/workai-board-web.log`. Never start a second one in tmux
(the port is taken), and never touch `tailscale serve`.
