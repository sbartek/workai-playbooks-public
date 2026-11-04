"""Card detail: fields, related cards, rendered markdown body. Read-only.

Related cards (depends on / needed by) can be focused with Tab / Shift+Tab
and opened with Enter; each opened card is a new screen on a stack, so Esc /
Backspace goes back one step with its scroll and focus intact, and q pops
the whole stack back to the board (which keeps its search and sort).
"""
from __future__ import annotations

import os
import shlex
import subprocess

from rich.table import Table
from rich.text import Text
from textual.app import ComposeResult, SuspendNotSupported
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.screen import Screen
from textual.widgets import Markdown, Static

from . import looks
from . import style as st


def editor_command() -> list[str]:
    """$VISUAL, then $EDITOR, then vi (as kanban-md does)."""
    for var in ("VISUAL", "EDITOR"):
        value = os.environ.get(var, "").strip()
        if value:
            return shlex.split(value)
    return ["vi"]


def flag_names(card: dict) -> str:
    names = {"claimable": "claimable", "blocked": "blocked", "waiting": "WAIT", "stale": "STALE", "overdue": "overdue",
             "due_soon": "due soon", "past_due": "PAST DUE",
             "waiting_old": "OLD wait"}
    return ", ".join(v for k, v in names.items() if card.get("flags", {}).get(k)) or "-"


def look_text(look) -> Text:
    """The project's border look as a legend: a sample corner in its colour and style, then the names."""
    if not look:
        return Text("-")
    colour, style = look
    chars = {"round": "\u256d\u2500\u2500", "double": "\u2554\u2550\u2550",
             "heavy": "\u250f\u2501\u2501", "dashed": "\u250f\u254d\u254d"}[style]
    t = Text(chars, style=looks.COLOURS[colour])
    t.append(f" {colour}, {style}")
    return t


def state_text(card: dict | None) -> Text:
    """What a card is doing now, in words: so a chain held up by a human shows who holds it.
    `waiting: question for the user`, `STALE, claimed by X`, `in progress (X)`,
    `todo, blocked by 01-004`, `todo, claimable`, `parked, not now`, `done`, `missing: no such card`."""
    if card is None:
        return Text("missing: no such card", style=st.RED_196)
    flags = card.get("flags", {})
    status = card["status"]
    if status in ("done", "archive"):
        return Text(status, style=st.DIM_241)
    if status == "parked":
        return Text("parked, not now", style=st.ORANGE_208)
    if status == "doing":
        if flags.get("waiting"):
            return Text(f"waiting: {card.get('waiting', '')}", style=st.RED_196)
        holder = card.get("claimed_by") or "?"
        if flags.get("stale"):
            return Text(f"STALE, claimed by {holder}", style=st.YELLOW_226)
        return Text(f"in progress ({holder})", style=st.CYAN_44)
    if flags.get("blocked"):
        deps = ", ".join(f"{card['project']}-{d}" for d in card.get("blocked_by", []))
        return Text(f"todo, blocked by {deps}", style=st.RED_196)
    return Text("todo, claimable", style=st.DIM_241)


def blockers_text(card: dict, lookup) -> Text:
    """One line per blocking card: `01-004: todo, blocked by 01-003`."""
    t = Text()
    for i, d in enumerate(card.get("blocked_by", [])):
        label = f"{card['project']}-{d}"
        if i:
            t.append("\n")
        t.append(f"{label}: ", style="bold")
        t.append_text(state_text(lookup(label)))
    return t


def fields_table(card: dict, look=None, lookup=None) -> Table:
    # Detail labels bold and 14 columns wide, as in kanban-md (MIT, see LICENSE-kanban-md).
    t = Table.grid(padding=(0, 1))
    t.add_column(width=14, style="bold", no_wrap=True)
    t.add_column()
    rows = [
        ("Project", f"{card['project']} {card.get('project_name', '')}"),
        ("Status", card["status"]),
        ("Border", look_text(look)),
        ("Priority", st.priority_word(card.get("priority"))),
        ("Repo", card.get("repo") or "-"),
        ("Depends", ", ".join(f"{card['project']}-{d}" for d in card.get("depends", [])) or "-"),
        ("Blocked by", blockers_text(card, lookup or (lambda label: None)) if card.get("blocked_by")
                       and card["status"] == "todo" else "-"),
        ("Dependents", ", ".join(f"{card['project']}-{d}" for d in card.get("dependents", [])) or "-"),
        ("Claimed by", Text(card.get("claimed_by") or "-", style=f"bold {st.CYAN_44}" if card.get("claimed_by") else "")),
        ("Worktree", card.get("worktree") or "-"),
        ("Branch", card.get("branch") or "-"),
        ("Started", card.get("started") or "-"),
        ("Waiting", Text(card.get("waiting") or "-", style=st.RED_196 if card.get("waiting") else "")
         + (Text(f"  ({card['waiting_days']} days)", style=st.DIM_241)
            if card.get("waiting") and card.get("waiting_days") is not None else Text(""))),
        ("Due", Text(card.get("due") or "-", style=st.RED_196 if card.get("flags", {}).get("past_due") else "")),
        ("Finished", card.get("finished") or "-"),
        ("Flags", flag_names(card)),
        ("File", Text(card.get("path", ""), style=st.DIM_241)),
    ]
    for label, value in rows:
        t.add_row(label, value)
    return t


class RelationItem(Static, can_focus=True):
    """One related card: `depends on` / `needed by`, label, priority, title, status."""

    def __init__(self, kind: str, label: str, card: dict | None) -> None:
        self.kind = kind
        self.label = label
        self.target = card
        t = Text()
        t.append(f"{kind:<11}", style=st.DIM_241)
        t.append(label, style="bold")
        if card is None:
            t.append("  (missing: no such card)", style=st.RED_196)
        else:
            t.append(f" {card.get('title', '')}  ")
            t.append("[", style=st.DIM_241)
            t.append_text(state_text(card))
            t.append(" \u00b7 ", style=st.DIM_241)
            t.append_text(st.priority_text(card.get("priority")))
            t.append("]", style=st.DIM_241)
        super().__init__(t)


class DetailScreen(Screen):
    BINDINGS = [
        Binding("escape,backspace", "back", "back", show=False),
        Binding("q", "board", "board", show=False),
        Binding("tab", "relation(1)", "next related", show=False, priority=True),
        Binding("shift+tab", "relation(-1)", "previous related", show=False, priority=True),
        Binding("enter", "open_relation", "open", show=False),
        Binding("j,down", "scroll(1)", "scroll", show=False),
        Binding("k,up", "scroll(-1)", "scroll", show=False),
        Binding("space,pagedown,ctrl+d", "page(1)", "page", show=False),
        Binding("b,pageup,ctrl+u", "page(-1)", "page", show=False),
        Binding("g,home", "edge(0)", "top", show=False),
        Binding("G,end", "edge(1)", "bottom", show=False),
        Binding("E", "edit", "editor", show=False),
    ]

    HINTS = [("j/k", "scroll"), ("space/b", "page"), ("tab", "related"), ("enter", "open"),
             ("E", "editor"), ("esc", "back"), ("q", "board")]

    def __init__(self, card: dict, lookup=None, look_of=None) -> None:
        """`lookup(label)` returns a card dict or None (used to resolve related cards);
        `look_of(project)` returns the project's (colour, style) border look or None."""
        super().__init__()
        self.card = card
        self.lookup = lookup or (lambda label: None)
        self.look_of = look_of or (lambda project: None)
        self.viewport = VerticalScroll(id="detail-scroll", can_focus=False)
        self._saved_scroll = 0.0

    def relations(self) -> list[RelationItem]:
        p = self.card["project"]
        items = []
        for kind, ids in (("depends on", self.card.get("depends", [])), ("needed by", self.card.get("dependents", []))):
            for i in ids:
                label = f"{p}-{i}"
                items.append(RelationItem(kind, label, self.lookup(label)))
        return items

    def compose(self) -> ComposeResult:
        title = Text()
        title.append(self.card["label"], style="bold")
        title.append(" " + self.card.get("title", ""), style="bold")
        with self.viewport:
            yield Static(title, id="detail-title")
            yield Static(fields_table(self.card, self.look_of(self.card["project"]), self.lookup), id="detail-fields")
            items = self.relations()
            if items:
                yield Static(Text("Related", style="bold"), id="detail-related-title")
                yield from items
            yield Markdown(self.card.get("body", ""), id="detail-body")
        yield Static(st.hint_line(self.HINTS), id="detail-hints")

    def action_back(self) -> None:
        self.app.pop_screen()

    def action_board(self) -> None:
        while isinstance(self.app.screen, DetailScreen):
            self.app.pop_screen()

    @property
    def items(self) -> list[RelationItem]:
        return list(self.query(RelationItem))

    def action_relation(self, step: int) -> None:
        items = self.items
        if not items:
            return
        if self.focused in items:
            i = (items.index(self.focused) + step) % len(items)
        else:
            i = 0 if step > 0 else len(items) - 1
        items[i].focus()

    def action_open_relation(self) -> None:
        item = self.focused
        if not isinstance(item, RelationItem):
            return
        if item.target is None:
            self.app.notify(f"{item.label}: no such card", severity="warning")
            return
        self.app.push_screen(DetailScreen(item.target, self.lookup, self.look_of))

    def on_screen_suspend(self) -> None:
        self._saved_scroll = self.viewport.scroll_y

    def on_screen_resume(self) -> None:
        # Coming back from a related card: keep the scroll as it was left.
        y = self._saved_scroll
        self.call_after_refresh(lambda: self.viewport.scroll_to(y=y, animate=False))

    def action_scroll(self, dy: int) -> None:
        self.viewport.scroll_relative(y=dy, animate=False)

    def action_page(self, direction: int) -> None:
        self.viewport.scroll_relative(y=direction * max(1, self.viewport.size.height - 2), animate=False)

    def action_edge(self, end: int) -> None:
        if end:
            self.viewport.scroll_end(animate=False)
        else:
            self.viewport.scroll_home(animate=False)

    def action_edit(self) -> None:
        """Hand the card file to the editor. The board itself never writes."""
        cmd = editor_command() + [self.card["path"]]
        try:
            with self.app.suspend():
                code = subprocess.call(cmd)
        except SuspendNotSupported:
            code = subprocess.call(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.app.notify(f"cannot start editor {cmd[0]}: {e}", severity="error")
            return
        if code:
            self.app.notify(f"editor exited with {code}", severity="warning")
        self.app.call_later(self.app.action_reload)
