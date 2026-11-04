"""The board: one column per status, cards from every workai hub. Never writes a card
(the only file it writes is the border-look map, see looks.py)."""
from __future__ import annotations

import time
from datetime import datetime
from pathlib import Path

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual import events
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Input, Static

from . import data, looks, query
from .detail import DetailScreen
from .style import (BG_236, CYAN_44, DIM_241, ORANGE_208, PURPLE_62, RED_196, SELECTED_MARKER, TEXT_230,
                    TEXT_252, YELLOW_226, age_style, age_text, hint_line, priority_text)

# `next` and `waiting` are views, not statuses: `next` = the todo cards listed
# in <workai>/next.md, in that order (report.py's "next"), not repeated in todo;
# `waiting` = the doing/ cards with `waiting:` filled, not repeated in doing
# (the files stay in doing/). Card 01-090.
# `parked` = backlog/parked/: wanted, deliberately not now; last, apart from todo
# so it never looks like work to pick (card 01-179).
COLUMNS = ("todo", "next", "doing", "waiting", "done", "parked")
STATUSES = ("todo", "doing", "done", "parked")
WAIT_MAX = 200  # the Waiting column exists to be read; only a very long text is cut
# Narrow mode (card 01-082): below this terminal width (a phone over SSH) the board shows ONE
# column at a time, full width, header `< doing (5) >`; h/l switch columns. `n` forces it.
NARROW_BELOW = 100


def card_age(card: dict, now: float) -> float:
    return now - (card.get("last_activity") or card.get("mtime") or now)


def dep_label(card: dict, dep_id: str) -> str:
    if dep_id in card.get("invalid_depends", []):
        return f"{dep_id} (invalid)"
    missing = " (missing)" if dep_id in card.get("missing", []) else ""
    return f"{card['project']}-{dep_id}{missing}"


def due_label(card: dict) -> str:
    """`PAST DUE 2026-10-20`, `due TODAY`, `due 2026-10-27 (3d)`; '' without a due date or once finished."""
    days = card.get("due_in_days")
    if days is None or card["status"] not in ("todo", "doing"):
        return ""
    if days < 0:
        return f"PAST DUE {card['due']}"
    return "due TODAY" if days == 0 else f"due {card['due']} ({days}d)"


def due_rank(card: dict) -> tuple:
    """Cards due within 14 days or past due first (soonest first), then the rest in their order."""
    flags = card.get("flags", {})
    soon = flags.get("due_soon") or flags.get("past_due")
    return (0, card.get("due") or "") if soon else (1, "")


def in_column(card: dict, column: str) -> bool:
    waiting = bool(card.get("flags", {}).get("waiting"))
    if column == "next":
        return bool(card.get("next"))
    if column == "waiting":
        return card["status"] == "doing" and waiting
    if column == "doing":
        return card["status"] == "doing" and not waiting
    if column == "todo":
        return card["status"] == "todo" and not card.get("next")
    return card["status"] == column


def column_cards(cards: list[dict], column: str, filter: str = "", sort_key: str = "priority",
                 reverse: bool = False, hide_blocked: bool = False) -> list[dict]:
    """Cards of a column after the filter, in board order (shared by the TUI and the web view).
    Next keeps next.md's order; the sort keys do not apply.
    In todo, dependency-blocked cards come after every claimable one (or are hidden).
    Cards due within 14 days or past due go first in every column but next and done, blocked or not
    (a deadline must not sink or hide)."""
    cards = [c for c in cards if c["status"] in STATUSES and in_column(c, column) and query.matches(c, filter)]
    if column == "next":
        return sorted(cards, key=lambda c: c["next"])
    cards = query.sort_cards(cards, sort_key, reverse)
    if column != "done":  # due within 14 days or past due: on top, whatever the sort (card 01-107)
        cards = sorted(cards, key=due_rank)
    if column == "todo":
        sinks = [c for c in cards if c.get("flags", {}).get("blocked") and due_rank(c)[0]]
        cards = [c for c in cards if c not in sinks]
        if not hide_blocked:
            cards += sinks
    return cards


def cut(text: str, n: int) -> str:
    return text if len(text) <= n else text[: n - 1] + "\u2026"


def card_text(card: dict, now: float) -> Text:
    """`01-009 Title`, then status part (flags, holder) · `priority: word`, then age.
    A waiting card has its question on a line of its own, before holder and priority."""
    t = Text()
    t.append(card["label"], style="bold")
    t.append(" " + card.get("title", ""))
    t.append("\n")
    flags = card.get("flags", {})
    status = card["status"]
    if status == "todo":
        if flags.get("blocked"):
            deps = [dep_label(card, d) for d in card.get("blocked_by", [])]
            more = f" +{len(deps) - 3} more" if len(deps) > 3 else ""
            t.append("BLOCKED", style=f"bold {RED_196}")
            t.append(" by " + ", ".join(deps[:3]) + more, style=RED_196)
        else:
            t.append("claimable", style=DIM_241)
    elif status == "doing":
        if flags.get("waiting"):
            t.append("WAIT ", style=f"bold {RED_196}")
            if flags.get("waiting_old"):
                t.append(f"OLD {card.get('waiting_days')}d ", style=f"bold {ORANGE_208}")
            t.append(cut(card.get("waiting", ""), WAIT_MAX), style=RED_196)
            t.append("\n")  # the question gets its own line(s); holder and priority below it
        elif flags.get("stale"):
            t.append("STALE ", style=f"bold {YELLOW_226}")
        t.append(card.get("claimed_by") or "?", style=f"bold {CYAN_44}")
    elif status == "parked":
        t.append("parked, not now", style=DIM_241)
    else:
        if flags.get("overdue"):
            t.append("overdue for archive ", style=ORANGE_208)
        t.append(f"finished {card.get('finished') or '?'}", style=DIM_241)
    due = due_label(card)
    if due:
        t.append(" \u00b7 ", style=DIM_241)
        t.append(due, style=f"bold {RED_196}" if flags.get("past_due") or card.get("due_in_days") == 0
                 else ORANGE_208 if flags.get("due_soon") else DIM_241)
    t.append(" \u00b7 ", style=DIM_241)
    t.append_text(priority_text(card.get("priority")))
    age = card_age(card, now)
    t.append("  ")
    t.append(age_text(age), style=age_style(age))
    return t


class CardBox(Static):
    """One card. Border = the project's look; selected = tint + marker on the title line."""

    def __init__(self, card: dict, now: float, look: tuple[str, str] | None = None) -> None:
        self.card = card
        self.look = look
        self.text = card_text(card, now)
        self.selected = False
        flags = card.get("flags", {})
        # Dependency-blocked todo cards are dimmed (and sink, see WorkaiBoard.visible).
        super().__init__(self.text, classes="dimmed" if flags.get("blocked") else "")
        if look:
            self.styles.border = (look[1], looks.COLOURS[look[0]])

    def set_selected(self, selected: bool) -> None:
        self.set_class(selected, "selected")
        if selected != self.selected:
            self.selected = selected
            self.update(Text(SELECTED_MARKER, style="bold") + self.text if selected else self.text)


class SearchInput(Input):
    """`/` search line: typing filters live, Enter keeps the filter, Esc clears it."""

    BINDINGS = [Binding("escape", "app.clear_search", "clear", show=False)]


class CardList(VerticalScroll, can_focus=False):
    pass


class Board(Horizontal):
    """The row of columns. Its Resize (the terminal's width changed) re-lays out narrow mode;
    the App's own Resize handler stops the event before a subclass handler sees it."""

    def on_resize(self, event: events.Resize) -> None:
        self.app.show_selection()


class Column(Vertical):
    def __init__(self, status: str) -> None:
        super().__init__(id=f"col-{status}")
        self.status = status
        self.header = Static(status, classes="col-header")
        self.body = CardList()

    def compose(self) -> ComposeResult:
        yield self.header
        yield self.body

    @property
    def boxes(self) -> list[CardBox]:
        return list(self.body.query(CardBox))


class WorkaiBoard(App):
    AUTO_FOCUS = None  # keys go to the board, not the hidden search line
    CSS = f"""
    Screen {{ layout: vertical; }}
    #board {{ height: 1fr; }}
    Column {{ width: 1fr; margin: 0 1 0 0; }}
    /* Styles below copied from kanban-md (MIT, see LICENSE-kanban-md). */
    .col-header {{ background: {BG_236}; color: {TEXT_252}; text-style: bold; padding: 0 1; width: 1fr; }}
    Column.active .col-header {{ background: {PURPLE_62}; color: {TEXT_230}; }}
    CardList {{ scrollbar-size: 0 0; }}
    CardBox {{ border: round $foreground 40%; padding: 0 1; height: auto; }}
    CardBox.selected {{ background: $boost; }}
    CardBox.dimmed {{ text-opacity: 55%; }}
    #search {{ height: 1; border: none; padding: 0 1; display: none; }}
    #search.visible {{ display: block; }}
    #status, #detail-hints {{ height: 1; color: {DIM_241}; padding: 0 1; }}
    #detail-scroll {{ height: 1fr; padding: 0 1; scrollbar-size-vertical: 1; }}
    #detail-title {{ padding: 1 0; }}
    #detail-fields {{ padding: 0 0 1 0; }}
    RelationItem {{ padding: 0 1; }}
    RelationItem:focus {{ background: {PURPLE_62}; color: {TEXT_230}; }}
    #detail-related-title {{ padding: 0 0 0 0; }}
    """

    BINDINGS = [
        Binding("h,left", "move(-1, 0)", "columns", show=False),
        Binding("l,right", "move(1, 0)", "columns", show=False),
        Binding("j,down", "move(0, 1)", "cards", show=False),
        Binding("k,up", "move(0, -1)", "cards", show=False),
        Binding("g,home", "edge(0)", "top", show=False),
        Binding("G,end", "edge(1)", "bottom", show=False),
        Binding("enter", "open", "open", show=False),
        Binding("slash", "search", "search", show=False),
        Binding("s", "sort(0)", "sort", show=False),
        Binding("S", "sort(1)", "reverse", show=False),
        Binding("escape", "clear_search", "clear", show=False),
        Binding("B", "toggle_blocked", "blocked", show=False),
        Binding("n", "toggle_narrow", "narrow", show=False),
        Binding("r", "reload", "refresh", show=False),
        Binding("q", "quit", "quit", show=False),
    ]

    HINTS = [("h/l", "columns"), ("j/k", "cards"), ("enter", "open"), ("/", "search"), ("s/S", "sort"), ("B", "blocked"), ("n", "narrow"), ("r", "refresh"), ("q", "quit")]

    def __init__(self, root: Path | None = None, report: Path | None = None,
                 archives: bool = False, poll: float = 2.0, full_reload: float = 300.0) -> None:
        super().__init__()
        self.root = Path(root) if root else data.default_root()
        self.report_path = Path(report) if report else data.find_report()
        self.archives = archives
        self.poll = poll
        self.full_reload = full_reload
        self.data: dict = {"hubs": [], "cards": []}
        self.col = 0
        self.rows = {s: 0 for s in COLUMNS}
        self.message = ""
        self.loaded_at = 0.0
        self._sig: tuple = ()
        self.columns = {s: Column(s) for s in COLUMNS}
        self.filter = ""
        self.sort_key = "priority"
        self.sort_reverse = False
        self.hide_blocked = False  # `B`: hide / show dependency-blocked todo cards
        self.force_narrow = False  # `n`: one column at a time even on a wide terminal
        self.header_text = {s: s for s in COLUMNS}  # `doing (5)`, before narrow mode's arrows
        self.looks = looks.Looks(self.root)

    # ---- layout ----
    def compose(self) -> ComposeResult:
        with Board(id="board"):
            for s in COLUMNS:
                yield self.columns[s]
        yield SearchInput(placeholder="search: words in title, #01-009, #009, @01", id="search")
        yield Static(id="status")

    async def on_mount(self) -> None:
        self.title = "workai-board"
        await self.action_reload()
        self.set_interval(self.poll, self.poll_changes)
        self.set_interval(self.full_reload, self.action_reload)

    # ---- data ----
    @property
    def cards(self) -> list[dict]:
        return [c for c in self.data.get("cards", []) if c["status"] in STATUSES]

    @property
    def next_info(self) -> dict:
        return self.data.get("next") or {}

    def in_column(self, card: dict, column: str) -> bool:
        return in_column(card, column)

    def blocked_hidden(self) -> int:
        """How many todo-column cards `B` is hiding now (0 when shown)."""
        if not self.hide_blocked:
            return 0
        return sum(1 for c in self.cards if self.in_column(c, "todo") and c.get("flags", {}).get("blocked")
                   and due_rank(c)[0] and query.matches(c, self.filter))

    def visible(self, column: str) -> list[dict]:
        """Cards of a column after the filter and sort (see column_cards; `B` hides blocked)."""
        return column_cards(self.cards, column, self.filter, self.sort_key, self.sort_reverse, self.hide_blocked)

    # The poll and full-reload timers can fire, or still be inside a reload's
    # awaits, while the app shuts down (quit, or run_test's teardown in the
    # tests): the widgets are already gone, so querying `#status` or mounting
    # cards raises (NoMatches, card 01-180). `is_running` turns False when the
    # shutdown starts; every step that touches widgets checks it first.
    async def poll_changes(self) -> None:
        if not self.is_running:
            return
        if data.signature(self.root, self.archives) != self._sig:
            await self.action_reload()

    async def action_reload(self) -> None:
        sig = data.signature(self.root, self.archives)
        try:
            new = data.load(self.root, self.report_path, self.archives)
        except data.ReportError as e:
            self.message = f"report failed: {e}"
            self._sig = sig
            self.update_status()
            return
        self._sig = sig
        self.data = new
        # Re-read the looks file (it may be edited by hand), then give a look to
        # every project with a card (any status), never only the filtered view.
        self.looks = looks.Looks(self.root)
        self.looks.assign(c["project"] for c in new.get("cards", []))
        self.loaded_at = time.time()
        self.message = ""
        await self.rebuild()

    # ---- rendering ----
    def selected_labels(self) -> dict:
        out = {}
        for s, col in self.columns.items():
            boxes = col.boxes
            if boxes and 0 <= self.rows[s] < len(boxes):
                out[s] = boxes[self.rows[s]].card["label"]
        return out

    async def rebuild(self) -> None:
        keep = self.selected_labels()
        now = time.time()
        for s, col in self.columns.items():
            if not self.is_running:  # shutting down mid-rebuild: see poll_changes
                return
            cards = self.visible(s)
            await col.body.remove_children()
            await col.body.mount_all([CardBox(c, now, self.looks.get(c["project"])) for c in cards])
            if s == "next":
                over = " over cap" if self.next_info.get("over_cap") else ""
                self.header_text[s] = f"next ({len(cards)}/{self.next_info.get('cap', 5)}){over}"
            elif s == "todo" and self.blocked_hidden():
                self.header_text[s] = f"todo ({len(cards)}, {self.blocked_hidden()} blocked hidden)"
            else:
                self.header_text[s] = f"{s} ({len(cards)})"
            labels = [c["label"] for c in cards]
            if keep.get(s) in labels:
                self.rows[s] = labels.index(keep[s])
            else:
                self.rows[s] = min(self.rows[s], max(0, len(cards) - 1))
        if self.is_running:  # the last mount may have awaited into a shutdown
            self.show_selection()

    @property
    def narrow(self) -> bool:
        return self.force_narrow or self.size.width < NARROW_BELOW

    def layout_columns(self) -> None:
        """Wide: every column side by side. Narrow: only the active column, full width,
        its header between arrows that say which way more columns are."""
        narrow = self.narrow
        for i, (s, col) in enumerate(self.columns.items()):
            col.display = not narrow or i == self.col
            text = self.header_text[s]
            if narrow:
                text = f"{'<' if i > 0 else ' '} {text} {'>' if i < len(COLUMNS) - 1 else ' '}"
            col.header.update(text)

    def action_toggle_narrow(self) -> None:
        self.force_narrow = not self.force_narrow
        self.show_selection()

    def show_selection(self) -> None:
        self.layout_columns()
        for i, (s, col) in enumerate(self.columns.items()):
            col.set_class(i == self.col, "active")
            for j, box in enumerate(col.boxes):
                sel = i == self.col and j == self.rows[s]
                box.set_selected(sel)
                if sel:
                    box.scroll_visible(animate=False)
        self.update_status()

    def update_status(self) -> None:
        if not self.is_running:  # no `#status` left once shutting down: see poll_changes
            return
        t = hint_line(self.HINTS)
        if self.message:
            t.append(self.message, style=RED_196)
        else:
            arrow = "desc" if self.sort_reverse else "asc"
            t.append(f"sort {self.sort_key} {arrow}  ", style=TEXT_252)
            if self.filter:
                t.append(f"filter {self.filter!r}  ", style=f"bold {CYAN_44}")
            if self.hide_blocked:
                t.append("blocked hidden (B shows)  ", style=f"bold {CYAN_44}")
            if self.force_narrow:
                t.append("narrow forced (n undoes)  ", style=f"bold {CYAN_44}")
            hubs = len(self.data.get("hubs", []))
            t.append(f"{hubs} hub{'s' if hubs != 1 else ''}, {len(self.cards)} cards", style=DIM_241)
            if self.loaded_at:
                t.append(f", read {datetime.fromtimestamp(self.loaded_at):%H:%M:%S}", style=DIM_241)
            for w in self.next_info.get("warnings", []):
                t.append(f"  {w}", style=ORANGE_208)
            # report.py's card warnings (unreadable cards, duplicate ids, bad fields).
            for w in self.data.get("warnings", []):
                t.append(f"  {w}", style=ORANGE_208)
            if self.looks.repeated:
                t.append(f"  {self.looks.repeated} project(s) share a border look (32 looks): read the number",
                         style=ORANGE_208)
            if self.looks.error:
                t.append(f"  {self.looks.error}", style=RED_196)
        self.query_one("#status", Static).update(t)

    # ---- navigation ----
    @property
    def current_status(self) -> str:
        return COLUMNS[self.col]

    @property
    def selected_card(self) -> dict | None:
        boxes = self.columns[self.current_status].boxes
        row = self.rows[self.current_status]
        return boxes[row].card if boxes and 0 <= row < len(boxes) else None

    def action_move(self, dx: int, dy: int) -> None:
        if dx:
            self.col = max(0, min(len(COLUMNS) - 1, self.col + dx))
        if dy:
            s = self.current_status
            n = len(self.columns[s].boxes)
            self.rows[s] = max(0, min(n - 1, self.rows[s] + dy)) if n else 0
        self.show_selection()

    def action_edge(self, end: int) -> None:
        s = self.current_status
        n = len(self.columns[s].boxes)
        self.rows[s] = (n - 1 if end else 0) if n else 0
        self.show_selection()

    def action_open(self) -> None:
        card = self.selected_card
        if card:
            self.push_screen(DetailScreen(card, self.card_by_label, self.looks.get))

    async def action_toggle_blocked(self) -> None:
        self.hide_blocked = not self.hide_blocked
        await self.rebuild()

    def card_by_label(self, label: str) -> dict | None:
        """Any card in the data, including archive/ ones the board hides."""
        return next((c for c in self.data.get("cards", []) if c["label"] == label), None)

    # ---- search and sort ----
    def action_search(self) -> None:
        box = self.query_one("#search", SearchInput)
        box.add_class("visible")
        box.display = True  # at once, so focus can land before the next key
        box.value = self.filter
        box.focus()

    async def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "search" and event.input.has_class("visible"):
            self.filter = event.value.strip()
            await self.rebuild()

    async def on_input_submitted(self, event: Input.Submitted) -> None:
        """Enter keeps the filter and gives the keys back to the board."""
        event.input.remove_class("visible")
        event.input.display = False
        self.set_focus(None)
        self.update_status()

    async def action_clear_search(self) -> None:
        box = self.query_one("#search", SearchInput)
        box.remove_class("visible")
        box.display = False
        self.set_focus(None)
        if self.filter:
            self.filter = ""
            await self.rebuild()

    async def action_sort(self, reverse: int) -> None:
        if reverse:
            self.sort_reverse = not self.sort_reverse
        else:
            self.sort_key = query.SORTS[(query.SORTS.index(self.sort_key) + 1) % len(query.SORTS)]
        await self.rebuild()
