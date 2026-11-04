"""Command line: `workai-board [--root DIR] [--archives] [--report PATH] [--tmux | --web [--port N]]`."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import __version__, data


def parse_args(argv=None):
    p = argparse.ArgumentParser(prog="workai-board", description="Read-only board of every workai project's backlog.")
    p.add_argument("--root", help="workai root (default: $WORKAI_ROOT or ~/workai)")
    p.add_argument("--archives", action="store_true", help="also show hubs in archives/")
    p.add_argument("--report", help="path to workai-open-project/report.py (default: $WORKAI_REPORT, the repo, the installed skill)")
    p.add_argument("--tmux", action="store_true",
                   help="start the board in a detached tmux session 'workai-board' (if not running) and print how to attach")
    p.add_argument("--tmux-socket", metavar="NAME",
                   help="tmux server socket name (tmux -L NAME); default: the normal server")
    p.add_argument("--web", action="store_true",
                   help="serve a read-only HTML view on 127.0.0.1 instead of the terminal board")
    p.add_argument("--port", type=int, default=None, metavar="N",
                   help="port for --web (default 8646); the host is always 127.0.0.1")
    p.add_argument("--version", action="version", version=f"workai-board {__version__}")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    root = Path(args.root).expanduser() if args.root else data.default_root()
    try:
        report = data.find_report(args.report)
    except data.ReportError as e:
        print(f"workai-board: {e}", file=sys.stderr)
        return 2
    if args.port is not None and not args.web:
        print("workai-board: --port needs --web", file=sys.stderr)
        return 2
    if args.web:
        from . import web

        try:
            web.serve(root, report, args.archives, web.DEFAULT_PORT if args.port is None else args.port)
        except OSError as e:
            print(f"workai-board: cannot listen on 127.0.0.1: {e}", file=sys.stderr)
            return 1
        return 0
    if args.tmux:
        from . import tmux

        try:
            _, message = tmux.start(root, report, args.archives, args.tmux_socket)
        except tmux.TmuxError as e:
            print(f"workai-board: {e}", file=sys.stderr)
            return 1
        print(message)
        return 0
    from .app import WorkaiBoard

    WorkaiBoard(root=root, report=report, archives=args.archives).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
