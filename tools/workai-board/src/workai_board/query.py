"""Search filter and sort keys for the board.

Filter: space-separated terms, all must match.
  word       case-insensitive substring of the title
  #01-009    label prefix (`#01-` = every card of project 01)
  #009       id prefix in any project
  @01        project number (`@1` works too)
"""
from __future__ import annotations

SORTS = ("priority", "id", "finished", "project")


def _prio(card: dict) -> int:
    p = card.get("priority")
    return p if p is not None else 9


SORT_KEYS = {
    "priority": lambda c: (_prio(c), c["project"], c["id"]),
    "id": lambda c: (c["id"], c["project"]),
    "finished": lambda c: (c.get("finished") or "", c["project"], c["id"]),
    "project": lambda c: (c["project"], _prio(c), c["id"]),
}


def term_matches(card: dict, term: str) -> bool:
    if term.startswith("#") and len(term) > 1:
        q = term[1:]
        return card["label"].startswith(q) if "-" in q else card["id"].startswith(q)
    if term.startswith("@") and term[1:].isdigit():
        return card["project"] == term[1:].zfill(2)
    return term.lower() in card.get("title", "").lower()


def matches(card: dict, query: str) -> bool:
    return all(term_matches(card, t) for t in query.split())


def sort_cards(cards, key: str = "priority", reverse: bool = False) -> list[dict]:
    return sorted(cards, key=SORT_KEYS[key], reverse=reverse)
