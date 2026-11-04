# youtrack-sync

One-way sync of backlog cards into the local YouTrack (hub 01 cards 116 and
147): each card with `youtrack: <issue id>` becomes a subtask of that group
issue. Python 3 standard library only.

```
python3 tools/youtrack-sync/youtrack_sync.py --dry-run      # what would change
python3 tools/youtrack-sync/youtrack_sync.py --hub 01       # one hub
python3 tools/youtrack-sync/youtrack_sync.py                # every hub with grouped cards
```

- A **group** is a YouTrack issue made by hand in the hub's project (name
  starting with the hub number, e.g. `01 Workai Playbooks`), Type `Group`.
  A card joins it with `youtrack: H01-5` in its frontmatter.
- Each such card is one issue `NN-NNN <title>`, Type `Task`, "subtask of"
  its group, State from the card: todo -> Todo (Next if in
  `~/workai/next.md`), doing -> Doing (Waiting if `waiting:` is filled),
  parked -> Parked (never Next; Todo in a project whose State field has
  no Parked value, or whose values cannot be read), done/archive -> Done.
  The group gets the State of its busiest card
  (Doing > Waiting > Next > Todo > Parked; Done when all are done).
- Boards (decided in card 01-149): one "NN Groups" per hub holds only that
  hub's group issues; one cross-hub "All Cards" holds the card issues of
  every joined hub in the State columns (the counterpart of workai-board).
  New card issues go on every board of their project whose name ends in
  "Cards", so a hub that joins adds its project to "All Cards".
- The card files are the source of truth: edit cards, not the subtasks.
  Only label and title leave the backlog, never a card body. Issues without
  an `NN-NNN` label are yours and never touched; a labelled issue whose card
  lost its group is deleted. A second run changes nothing.
- Token: `workai-secret get youtrack/api` at run time. URL:
  http://127.0.0.1:8645 (`YOUTRACK_URL`).

Tests: `tests/test-youtrack-sync.sh` (fake YouTrack, no network).
