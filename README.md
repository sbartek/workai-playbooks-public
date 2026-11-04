# workai-playbooks

Skills, MCP servers, tools, config and an install script for working with AI
in one unified way. Claude Code first.

## Layout

```
skills/<name>/SKILL.md     one folder per skill (extra files beside it if needed)
install.sh                 sets up an agent (skills, tools, settings, MCP servers): install.sh claude
claude/                    Claude Code settings fragment, MCP server list and wrappers
scripts/                   checks and helpers
deps/                      tool installers for a new machine and the shared tool list
tools/workai-board/        read-only terminal board of every hub's backlog
tools/workai-secret/       one command for local secrets (keychain, secret-tool, pass, systemd-creds)
tools/youtrack-sync/       one-way sync of grouped backlog cards into YouTrack subtasks
tests/                     tests for the scripts
.githooks/                 optional git hooks (pre-commit runs the checks)
.github/workflows/         CI (reusable outcome-ci.yml + this repo's ci.yml) and AI review of pull requests
VERSION, CHANGELOG.md      releases, see below
```

The repo is the single source of truth. Agents never get their own copies:
`install.sh <agent>` links each skill into the place that agent reads.

## Installing skills, settings and MCP servers

```
./install.sh claude                    # live: link skills/* of this checkout into ~/.claude/skills/, merge settings, add MCP servers
./install.sh claude --release [vA.B.C] # released: link a release worktree (default: newest tag)
./install.sh claude --check            # report missing, broken, wrong or orphan links
./install.sh claude --uninstall        # remove only the links this script made
./install.sh claude ... --force        # take the links over from another existing checkout
./install.sh claude --settings-only    # only settings and MCP servers (skills stay where they are)
./install.sh claude --skills-only      # only the skill links
./install.sh claude --claude-md-only   # only ~/.claude/CLAUDE.md (created from the template if missing)
```

**Live** links point at the checkout you run it from: every merge or `git
pull` there changes the skills of every session at once. **Release** links
point at `~/.local/share/workai-playbooks/releases/vA.B.C/` (a detached git
worktree of the tag, locked; `WORKAI_RELEASES_DIR` moves it), so main can
move without changing what agents read; a new release is picked up by
running `--release` again. The open-project report prints which one is in
use (`playbooks: 1.1.0 (release v1.1.0)` or `(live checkout, N commits after
v1.0.0)`).

It never touches a skill it did not install, and it will not take the links
over from another checkout that still exists (a second clone, a card
worktree, or the live checkout when switching to a release) without
`--force`; links into a checkout that is gone are repaired, and moving from
one release to a newer one needs no `--force`. Run from a linked worktree it
warns. `tests/test-install.sh` and `tests/test-install-release.sh` run it
against a throwaway folder and throwaway clones.

**Global CLAUDE.md.** `~/.claude/CLAUDE.md` is yours: `install.sh claude`
never changes one that is there (a file, or any symlink except the old link
below; it prints `kept`).
Only when it is missing does it copy `claude/CLAUDE.md.template` (a short,
generic Communication Style and Workflow section) there as a plain file,
recorded with its sha256 in the manifest; `--check` reports `missing`,
`kept` or `ours`, and `--uninstall` removes it only while it is still
byte-identical to what was written. Edit your rules in `~/.claude/CLAUDE.md`
itself. Machines with the link older versions made (into a checkout or a
release of this repo) get it replaced by a plain file with the same content,
once (`migrated`); a link into a removed release or checkout is filled from
git history (the tag, else that checkout's or this repo's history). `tests/test-install-claude-md.sh`.

**Settings.** `claude/settings.fragment.json`, plus
`claude/settings.fragment.<os>.json` for the OS in `uname -s` (lower case,
e.g. `darwin`), is merged into `~/.claude/settings.json` with `jq`: objects
key by key, arrays unioned, no key ever removed, and a value that is already
there and different is reported (`differs`) and left alone. The file is
written only when the result differs, after a backup
`settings.json.workai-<time>.bak`; a second run changes nothing. What was
added (and only that) is recorded in `~/.claude/workai-installed.json`, so
`--uninstall` removes exactly that and keeps anything changed since.
Included today: `tui: fullscreen`, `skipWorkflowUsageWarning: true`, and on
macOS the auto-mode soft_deny `Bash(tmutil delete:*)` (next to `$defaults`,
which keeps the built-in rules). No permission rules, hooks or machine
details: see hub card 01-006 for the list and the reasons.

**MCP servers.** Each entry of `claude/mcp.json` is added with `claude mcp
add --scope user <name> -- <checkout>/<command>` unless `claude mcp get
<name>` already finds it (a registration made by hand is reported and left
alone; `--force` re-registers only one this script made). `~/.claude.json`
is never edited directly. No secret is passed to `claude mcp add`: a server
that needs one is a wrapper that reads it at launch.

- `youtrack`: the local YouTrack Server's built-in MCP endpoint
  (`http://127.0.0.1:8645/mcp`, hub 01 `notes/youtrack/`), through
  `claude/mcp/youtrack-mcp.sh`, which reads the API token with
  `workai-secret get youtrack/api` (else
  `~/.config/workai/youtrack-token`, mode 600) and runs a pinned
  `mcp-remote` with the token in its environment, not its arguments. Plain
  OAuth does not work yet: YouTrack has no dynamic client registration, so
  it needs an OAuth client registered by hand first. Needs Node.js (`npx`).

`tests/test-install-settings.sh` runs all of this in a throwaway HOME with a
fake `claude` CLI.

## Installing the tools (new machine)

```
deps/install-mac.sh              # Mac, Apple Silicon or Intel: Homebrew, else MacPorts
deps/install-mac.sh --check      # list missing tools and skills, change nothing
deps/install-mac.sh --dry-run    # print the commands only
deps/install-mac.sh --brewfile   # the Brewfile for every tool
```

Installs only what is missing from `deps/tools.txt` (git, tmux, jq,
python3 >= 3.11, gh, gitleaks, workmux, Claude Code), then runs `install.sh
claude` (`--release` passes through). Homebrew: `brew bundle --no-upgrade`
on a Brewfile of the missing tools. MacPorts: `sudo port install`, `port
select` for python3, workmux as a release binary whose SHA-256 is pinned in
`deps/release-binaries.txt` (into `~/.local/bin`), Claude Code with
Anthropic's native installer. A second run changes nothing.

```
deps/install-ubuntu.sh           # Ubuntu 24.04 LTS or newer, x86_64 or arm64 (sudo, or root in a container)
deps/install-ubuntu.sh --check   # same --check / --dry-run / --release as the Mac script
```

Same tool list. Ubuntu packages with `apt-get`; gh from GitHub's apt
repository and Claude Code from Anthropic's (stable channel; the signing
key's fingerprint is checked); workmux and gitleaks as the pinned release
binaries. `tests/test-install-deps.sh` runs every route against fake
package managers.

**Clean-machine test** (before a release; slow, needs Docker):

```
scripts/clean-machine-test.sh                 # ubuntu:24.04, ubuntu:26.04 containers + mac-home
scripts/clean-machine-test.sh ubuntu:24.04    # one target
scripts/clean-machine-test.sh --break mac-home   # sabotaged install: must FAIL
scripts/clean-machine-test.sh mac-vm          # clean macOS VM (tart), only when named
```

Each target installs a copy of the checkout in a new environment: `--check`
(missing), `--dry-run`, install, the skills/settings/MCP/CLAUDE.md/tools in
place, `--check` (nothing missing), a second run that prints only `ok` lines
and changes no file or package, `install.sh claude --uninstall`, everything
gone. PASS/FAIL per step. `mac-home` is this Mac's tools with a throwaway
HOME and a fake `claude` (never the real `~/.claude`). `mac-vm` is a clean
Mac: a throwaway [tart](https://tart.run) clone of the local base VM
`workai-clean-mac` (cirruslabs macOS vanilla, no Homebrew), reached by ssh
with the image's default password admin/admin (`SSH_ASKPASS`; no key, agent or
ssh config of this Mac goes in); it installs Homebrew, runs
`deps/install-mac.sh` and deletes the clone on any exit. It needs 40 GB free
and runs one clone at a time; a run takes about 3 minutes on an M5. `tests/test-clean-machine.sh`
runs the script only with `WORKAI_CLEAN_MACHINE=1`.

## workai-board

A read-only terminal board of every project hub's backlog: columns todo /
next / doing / waiting / done / parked, cards labelled `01-009 Title` over a second
line with the holder or WAIT / STALE / BLOCKED, `priority: high|normal|low`
and the age. Next and Waiting are views, not folders: Next shows the todo
cards listed in `~/workai/next.md` (at most 5, in that order; see the
workai-backlog skill), Waiting the cards in `doing/` with `waiting:` filled
(their question on a line of its own), so Doing holds only cards being worked
on. In todo, cards blocked by unfinished dependencies come after every
claimable card, dimmed; `B` hides or shows them. The last column, parked,
holds the cards in `backlog/parked/` (wanted, deliberately not now), apart
from todo so they never look like work to pick.
Each project's cards share a border look (8 colours x 4 border styles), kept
for good in `<workai>/.workai-board/colours.json` (hand-editable; the only
file the board writes). It never writes a card. Its data comes from
`workai-open-project/report.py --json --all`, so the backlog rules live in one
place. Base look copied from [kanban-md](https://github.com/antopolskiy/kanban-md)
(MIT, `tools/workai-board/LICENSE-kanban-md`).

Install (Python 3.11+, the only dependency is Textual):

```
uv tool install --editable tools/workai-board    # Mac or Ubuntu; puts workai-board on PATH
pipx install --editable tools/workai-board       # same, with pipx
sudo port install py314-textual                  # MacPorts (not checked yet): Textual from ports, then
python3.14 -m venv --system-site-packages ~/.local/share/workai-board
~/.local/share/workai-board/bin/pip install --no-deps --editable tools/workai-board
ln -s ~/.local/share/workai-board/bin/workai-board ~/.local/bin/
```

Editable installs find `report.py` in this clone. Otherwise it is taken from
`$WORKAI_REPORT`, then `~/.claude/skills/workai-open-project/report.py` (the
installed skill).

```
workai-board                  # all hubs in ~/workai/projects ($WORKAI_ROOT or --root to change)
workai-board --archives       # also hubs in archives/
workai-board --tmux           # run it in a detached tmux session (if not running yet)
tmux attach -t workai-board   # look at it from any terminal tab; Ctrl-b d detaches
```

With `--tmux` the board lives in a tmux session named `workai-board` and
keeps refreshing while nobody is attached; a second `--tmux` only prints how
to attach. No tmux config is needed, and the board is started with a
256-colour `TERM` if the pane does not have one. `q` inside the session
quits the board and ends the session. `--tmux-socket NAME` uses a separate
tmux server (`tmux -L NAME`), as the tests do. Agents use the
`workai-board` skill (`skills/workai-board/board.sh start|restart|stop|status|show`)
to run it, restart it after a code change, and read its screen.

Keys: `h`/`l` columns, `j`/`k` cards, `g`/`G` top/bottom, `Enter` open the
card, `/` search, `s` sort, `S` reverse, `B` hide/show blocked todo cards,
`n` narrow mode, `r` refresh, `q` quit.

Narrow mode: on a terminal narrower than 100 columns (a phone over SSH) the
board shows one column at a time, full width, its header between arrows
(`< doing (2) >`); `h`/`l` switch columns, and resizing back to a wide
terminal shows every column again. `n` forces narrow mode on a wide terminal
(and back).

Search filters as you type; `Enter` keeps the filter, `Esc` clears it. Terms
are separated by spaces and all must match: a word matches the title,
`#01-009` a label prefix (`#01-` = all of project 01), `#009` an id in any
project, `@01` a project. `s` cycles the sort: priority, id, finished,
project. In a card (fields, then the body rendered as
markdown): `j`/`k` scroll, `space`/`b` page, `g`/`G` top/bottom, `E` open the
file in `$VISUAL`, `$EDITOR` or `vi` (the board itself never writes). The
card lists the cards it depends on and the cards that need it (missing ids
included), each with its state (`waiting: question for the user`, `todo,
blocked by 01-084`, `in progress (agent)`, `done`); a blocked card has a
`Blocked by` field with one such line per blocker, so a chain held up by a
human shows where. `Tab`/`Shift+Tab` focus one, `Enter` opens it, `Esc`/`Backspace`
goes back one step with scroll and focus restored, `q` returns to the board
with its search and sort. Card files are checked every 2 s and the report re-run only when one
changed (and every 5 minutes, so STALE ages).

### Web view (`--web`)

The same board as a read-only web page, for reading on a phone:

```
workai-board --web                # http://127.0.0.1:8646/ ; Ctrl-C stops it
workai-board --web --port 8650    # another port; the host is always 127.0.0.1
```

Same columns, order, card lines, flags (WAIT / OLD / STALE / BLOCKED, due
dates) and project looks as the terminal board (the column logic and card
text are shared code); tap a card to see its body. Each page load re-reads
the cards when a card file changed (and at least every 5 minutes); reload the
page to refresh. Standard library only (`http.server`), no JavaScript, no
external CSS or fonts. It listens on 127.0.0.1 only (there is no host
option), answers only `GET /` and `HEAD /` (other paths 404, other methods
501: nothing can be written through it) and sends `Cache-Control: no-store`.

From the phone, over Tailscale (tailnet only, HTTPS, Tailscale identity):

```
tailscale serve --bg 8646         # then open https://<this-mac>.<tailnet>.ts.net/ on the phone
tailscale serve status            # what is being served
tailscale serve --https=443 off   # stop serving it (the board itself keeps running until Ctrl-C)
```

Never `tailscale funnel`: that publishes it to the internet.

To keep it running without a terminal, on a Mac, install it as a LaunchAgent
(`com.bartek.workai-board-web`): it starts at login and launchd restarts it
if it dies (`RunAtLoad` + `KeepAlive`). Run it from the main checkout (the
plist points at that checkout's `tools/workai-board/.venv`, so run `uv sync`
there first; a card worktree is refused):

```
tools/workai-board/launchagent.sh install [--port N]   # writes ~/Library/LaunchAgents/com.bartek.workai-board-web.plist, loads it
tools/workai-board/launchagent.sh status               # loaded, pid; exit 3 when not installed
tools/workai-board/launchagent.sh uninstall            # unloads it, removes the plist
launchctl kickstart -k gui/$(id -u)/com.bartek.workai-board-web   # restart, e.g. after a board code change
```

Log: `~/Library/Logs/workai-board-web.log`. Installing again with the same
port changes nothing; another port rewrites and reloads it. Still 127.0.0.1
only; `tailscale serve` is set up separately (above) and survives a reboot by
itself. Elsewhere (Linux, no LaunchAgent) use tmux:
`tmux new-session -d -s workai-board-web 'workai-board --web'`.

Development: `cd tools/workai-board && uv run pytest` (its own `.venv`,
ignored by git); `uv run workai-board` runs it from the clone.

## Skill format

Skills are written once and must stay readable by agents other than Claude.

- `SKILL.md` starts with YAML frontmatter holding only `name` and
  `description`, followed by a markdown body.
- No agent-specific frontmatter fields (for example Claude Code's
  `allowed-tools` or `disable-model-invocation`). If an agent needs one, the
  install step for that agent adds it, not the source file.
- `name` equals the folder name and starts with `workai-`, so it never collides
  with skills installed from elsewhere (e.g. an existing `worktree` skill).
- `description` says what the skill does and when to use it, in one or two
  sentences: agents decide from it whether to load the skill.
- Paths in the body are relative to the skill folder or written from the
  workai root (`projects/NN-name/...`), never absolute to one machine.

- Limits that all checked agents accept: `name` is lowercase kebab-case, at
  most 64 characters, equal to the folder name; `description` is 1 to 1024
  characters.

### Checks

- `scripts/check-skills.py` checks every skill against the rules above without
  running an agent. `tests/test-check-skills.sh` tests the checker itself.
- `tests/test-report.sh` runs `workai-open-project/report.py` (text and
  `--json`) against a fixture workai.
- `tests/test-find-list.sh` runs `report.py --list` and the open-by-name
  lookup against the eval fixture (`evals/_fixtures/workai.sh` plus
  `fixture_more_hubs` and `fixture_merged_hubs`) under a throwaway `$HOME`.
- To run it before every commit: `git config core.hooksPath .githooks` (once
  per clone).
- `scripts/run-tests.sh` runs the whole suite (every `tests/test-*.sh`, the
  workai-board pytest when `uv` is installed, then `check-skills.py`;
  `SKIP_TESTS=<regex>` skips by name). Run it before a push.

### CI for outcome repos

`.github/workflows/outcome-ci.yml` (card 01-085) is a reusable workflow
(`workflow_call`) every outcome repo calls instead of copying it: lint (ruff
for Python, shellcheck for shell, with the repo's own `ruff.toml` /
`.shellcheckrc`), the repo's test command, and a basedpyright type check
(`off`, `report` = warn only, or `enforce`). The caller's workflow file is the
per-repo config; the example is at the top of `outcome-ci.yml`, and this
repo's own is `.github/workflows/ci.yml` (lint + `scripts/run-tests.sh`,
typecheck `report` until its type errors are fixed). AI review is its own
workflow, `ai-review.yml`. A private repo can call `outcome-ci.yml` only once
this repo's Settings > Actions > General > Access allows repositories owned
by the user. `tests/test-ci.sh` checks the workflows and `run-tests.sh`.

### Behaviour evals

`scripts/run-evals.sh` runs `evals/*/case.yaml` through `claude plugin eval`:
each case builds a fake `~/workai` (`evals/_fixtures/workai.sh`), gives Claude
a task, and grades the files and git state it leaves plus its answer (LLM
judge: Sonnet). Each case runs 3 times. It always runs on the claude.ai
subscription: the script drops any `ANTHROPIC_API_KEY` and refuses to start
unless `claude auth status` says claude.ai. The reported dollar cost is an
API-price estimate (about $0.07 per run); on the subscription it uses the
plan's usage allowance instead:
run it before a release, not on every commit. `--ablation with-without` also
runs without the skills to show what they add. `.claude-plugin/plugin.json`
exists only so the eval can load the skills; daily use goes through
`install.sh`.

Inside a run the permission mode is dontAsk: a Bash command runs only if
every part of it matches a granted tool (`run-evals.sh` and the case's
`allowed_tools`), so `python3 x; echo $?` and `cd d && git ...` are denied (the
skills now say to run their scripts unchained). Bash works for the cases
today; `~/.docker` symlinks no longer stop them (Claude Code 2.1.308).

Known blocker on this Mac: git cannot run inside an eval run. The run's
sandbox blocks Apple's git, because its `git-credential-store`/`-cache` are
symlinks to the git binary and the sandbox denies credential helpers; the
`/usr/bin/git` shim also cannot write its xcrun cache. `report.py` then shows
every hub as "clean", so the cases that grade git state fail
(open-project-by-name: 0.75) or pass without checking it (list-projects).
Likely fix (unverified): a non-Apple git earlier on `PATH` (`brew install git`);
`run-evals.sh` warns while `/usr/bin/git` is the one found (card 072).

### opencode behaviour test

`python3 scripts/opencode-behaviour.py` runs four cases ("work on project 1",
"what's waiting on me?", "what's the status of card 001?", and a `canary`
case that asks for a file in the real `~/workai`) in opencode, headless, with
a free zero-retention model (deepseek-v4.1-flash-free by default; `--model`
takes only glm-5.3-flash-free besides). It
prints PASS/FAIL per case and run and exits 1 on a failure. A case passes
when the skill was loaded, its `report.py` ran in the right mode, and the
answer names the fixture's cards. Each run has its own sandbox under `/tmp`:
fake `HOME` with a copy of the skills and the fixture workai, private XDG
dirs (no opencode login), `WORKAI_ROOT`, an `opencode.json` denying external
directories, edits and most shell commands, never `--auto`; on macOS the
process also runs under `sandbox-exec` with the real home denied (in the
first runs opencode's own rules did not stop the `read` tool on a real
path: the OS sandbox did). A canary file with a random token sits in the
real `~/workai` during the run; any transcript holding it fails. `--break
<skill>` sabotages that skill's copy (its cases must fail), `--runs N`,
`--case GLOB`, `--keep`, `--dry-run` (sandbox checks, no model),
`--self-test` (scorer on canned transcripts). `tests/test-opencode-behaviour.sh`
runs the model-free parts; the model runs only with `WORKAI_OPENCODE_TEST=1`.

### Which agents read it (checked 2026-10-24)

| Agent | User-level skill folders | Notes | Source |
|---|---|---|---|
| Claude Code | `~/.claude/skills/` | in use on this Mac | — |
| Codex | `~/.agents/skills/` (and deprecated `$CODEX_HOME/skills`) | follows symlinked skill folders at user scope; optional extra field `short-description` | `openai/codex` `codex-rs/ext/skills/src/host_roots.rs`, `loader/host.rs` (commit 970111f) |
| Gemini CLI | `~/.gemini/skills/` or `~/.agents/skills/` | `.agents/skills` named as the [Agent Skills](https://agentskills.io) alias | `google-gemini/gemini-cli` `docs/cli/creating-skills.md` |
| opencode | `~/.config/opencode/skills/`, `~/.claude/skills/`, `~/.agents/skills/` | optional `license`, `compatibility`, `metadata`; unknown fields ignored | `anomalyco/opencode` `packages/web/src/content/docs/skills.mdx` |
| Cline | `~/.cline/skills/` | | `cline/cline` `docs/customization/skills.mdx` |

Consequence for installing: `~/.agents/skills/` is read by Codex, Gemini CLI
and opencode, so one set of links there covers three agents; Claude Code needs
`~/.claude/skills/` (which opencode also reads). Not checked: goose, and
whether agents other than Codex follow symlinks.

## Versions and releases

Releases are `a.b.c`: the `VERSION` file, an entry in `CHANGELOG.md`, and a git
tag `vA.B.C`.

- **a (major):** the workai structure changed; project hubs need migrating.
  The changelog entry must include a **Migration** section with the steps, or
  "No hub changes".
- **b (minor):** new skills, scripts or options; nothing existing breaks.
- **c (patch):** fixes and wording.

Same major means same structure. Each hub records the version it conforms to.

A change to any `skills/*/SKILL.md` is a rule change: it needs at least a
minor bump, never only a patch.

### Cutting a release

```
scripts/release.sh --check     # exit 1 when commits since the last tag are unreleased
scripts/release.sh a.b.c       # on main, clean tree
```

It moves the `[Unreleased]` changes into a new `## [a.b.c] — YYYY-MM-DD`
entry in `CHANGELOG.md` (refusing a major without a `### Migration`
section, and a patch when a SKILL.md changed), writes `VERSION`, commits
`Release a.b.c` and tags `va.b.c`. It does not push: `git push
--follow-tags` after the user's OK. Then `./install.sh claude --release` on
each machine that uses releases.
