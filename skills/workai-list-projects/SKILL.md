---
name: workai-list-projects
description: List the workai projects - when the user says "list active projects", "list archived projects", "list all projects", "what projects do I have" or similar, print every numbered hub in ~/workai with its goal, cards in progress (WAITING or STALE) and uncommitted or unpushed work. Also answers "what's waiting on me", "what needs me", "what am I blocking": cards due within 14 days or past due, then every card across the active projects waiting on the user, then stale cards, then cards held up only by those. Read-only. To open one project use workai-open-project instead.
---

# List workai projects

Active projects are the hubs in `~/workai/projects/`, archived ones the hubs
in `~/workai/archives/` (see the workai-structure skill). Folders there
without a number are not hubs and are not listed.

## Steps

1. Run the report script of the workai-open-project skill, choosing the mode
   from the request: `active` (the default: "list projects", "active
   projects"), `archived` ("archived", "closed", "old projects") or `all`.

   ```
   python3 <this skill's folder>/../workai-open-project/report.py --list active
   ```

   Run it alone, with nothing chained (`;`, `&&`, `echo $?`): sessions that
   allow only `python3` refuse a chained command.

   It changes nothing. Each hub is one line `NN  Title  (area/NN-name)`,
   followed by its goal, each card in `doing/` with who holds it and any
   WAITING or STALE flag, a `parked (N): ids` line when the hub has parked
   cards (not now: not open work, mention only if asked), and a `git:` line only when something is
   uncommitted, unpushed or has no upstream.
2. Show the user the list, compactly: number, title and goal per hub. Then
   point out, if any: cards WAITING (they need the user), STALE cards, and
   hubs or repos with uncommitted or unpushed work. Do not reprint lines that
   say nothing.
   If the script could not run, say so and list only what you read from the
   folders; never state git state (clean, pushed) you did not check.
3. Stop. Do not open a project, claim a card, commit or push. If the user
   then names a project, open it with the workai-open-project skill.

## What's waiting on me

When the user asks what is waiting on them (what needs them, what they are
blocking, what the agents are waiting for), run instead, alone:

```
python3 <this skill's folder>/../workai-open-project/report.py --waiting
```

It reads every hub in `~/workai/projects/` and prints five sections:

- `due within 14 days or past due`: todo and doing cards whose `due:` date
  is near or gone, soonest first, `PAST DUE` marked. Real deadlines: show
  them before anything else, with the date.
- `waiting on you`: each card in `doing/` with `waiting:` filled: label,
  title, project, the question (`waiting:`), the last item of its Notes and
  the card file, where the Notes say more.
- `stale`: cards in `doing/` with no activity for 24 hours (nobody is
  waiting on the user, but nobody is working either).
- `blocked only by waiting cards`: todo cards that answering would unblock.
- `parked, not now`: cards in `backlog/parked/`. Nobody waits on them and
  they have no deadline: mention the count in one line, never as a request.

Show the due cards first, then the waiting cards, grouped by project, each with its question in
one line; offer to open the card's Notes for the one the user picks. Then the
stale cards and the cards that answering would unblock, briefly. Empty
sections: one line ("nothing stale"). Do not answer a question, clear
`waiting:` or claim anything unless the user asks.

## Script

[report.py](../workai-open-project/report.py) holds the backlog rules for
every workai skill and tool; this skill only calls its `--list` and
`--waiting` modes.
