"""Look shared by the board and the detail view."""
from __future__ import annotations

from rich.text import Text

# Colours copied from kanban-md's internal/tui/board.go (MIT, see
# LICENSE-kanban-md): xterm-256 numbers converted to hex. Card borders no
# longer use kanban-md's grey / purple / red: since card 01-092 the border is
# the project's look (looks.py), blocked / WAIT is a text flag, and the
# selected card has a background tint and a title marker.
PURPLE_62 = "#5f5fd7"   # active column header background, focused related card
RED_196 = "#ff0000"     # blocked / WAIT text; errors; age from 168 h
TEXT_252 = "#d0d0d0"    # column header text; highlighted shortcut letters
BG_236 = "#303030"      # column header background
TEXT_230 = "#ffffd7"    # active column header text
ORANGE_208 = "#ff8700"  # priority high (priority: 1)
YELLOW_226 = "#ffff00"  # priority normal (priority: 2)
GREY_242 = "#6c6c6c"    # priority low (priority: 3); age under 1 h
CYAN_44 = "#00d7d7"     # claim / holder
DIM_241 = "#626262"     # dim text, hints, status bar
GREEN_34 = "#00af00"    # age from 1 h

PRIORITY_COLOUR = {1: ORANGE_208, 2: YELLOW_226, 3: GREY_242}
# Display only: card files keep `priority: 1|2|3`.
PRIORITY_WORD = {1: "high", 2: "normal", 3: "low"}
SELECTED_MARKER = "\u25b6 "  # in front of the selected card's title line


def priority_word(prio) -> Text:
    """`high` / `normal` / `low` (`?` when missing), coloured by priority."""
    return Text(PRIORITY_WORD.get(prio, "?"), style=PRIORITY_COLOUR.get(prio, GREY_242))


def priority_text(prio) -> Text:
    """`priority: high`, the colour on the word only."""
    t = Text("priority: ", style=DIM_241)
    t.append_text(priority_word(prio))
    return t


def age_style(seconds: float) -> str:
    """kanban-md's age colours: 242 <1 h, 34 from 1 h, 226 from 24 h, 208 from 72 h, 196 from 168 h."""
    h = seconds / 3600
    if h >= 168:
        return RED_196
    if h >= 72:
        return ORANGE_208
    if h >= 24:
        return YELLOW_226
    if h >= 1:
        return GREEN_34
    return GREY_242


def age_text(seconds: float) -> str:
    if seconds < 3600:
        return f"{max(0, int(seconds // 60))}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"


def hint_line(hints) -> Text:
    """Status-bar hints: shortcut keys in 252, the rest dim (kanban-md)."""
    t = Text()
    for key, what in hints:
        t.append(key, style=TEXT_252)
        t.append(f" {what}  ", style=DIM_241)
    return t
