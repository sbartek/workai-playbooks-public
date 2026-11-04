# Changelog

Versions are `a.b.c`, tagged `vA.B.C`. The major number `a` is the workai
structure version: same major, same structure. A major bump means project hubs
must be migrated, and its entry has a **Migration** section with the steps (or
"No hub changes"). Projects in the old, pre-hub layout count as major 0.

## [Unreleased]

### Changed
- Skills, tools, tests and evals say "the user" instead of a personal name, and
  examples use made-up project names (Ceramics, myapp), ready for a public
  copy (card 01-156).

### Fixed
- `tests/test-find-list.sh`: the WAITING line test no longer fails once the
  fixture card is over 7 days old (OLD flag).

## [1.8.1] — 2026-10-27

### Fixed
- `install.sh --release` moves the MCP servers it added to the new release (card 01-181): a registration in the manifest whose command is under `$WORKAI_RELEASES_DIR` (an older release) is re-registered with the new release's command (`replaced mcp`), as skill and tool links already move; any other differing registration is still left as it is without `--force`. Tests in `tests/test-install-release.sh`.
- workai-board no longer crashes when its poll or full-reload timer fires while the app shuts down (card 01-180): `poll_changes`, `rebuild` (before each column and before the selection) and `update_status` return once `is_running` is False, so a reload caught in run_test's teardown (or a quit) no longer raises `NoMatches: No nodes match '#status'`. That race made `test_auto_refresh_picks_up_changes` flaky on CI (PRs #13, #14, #15); under CPU load it failed 7 of 100 runs before, 0 of 100 after.

### Changed
- AI PR review falls back to another zero-retention model when the free quota runs out (card 01-183): `ai-review.yml` has an ordered `MODELS` list (`opencode/deepseek-v4.1-flash-free`, then `opencode/glm-5.3-flash-free`), passed to `scripts/opencode-review.sh` as `AI_REVIEW_MODELS` (environment, so an older base script keeps its single default). The script tries the models in order and moves on only when opencode fails with Zen's free-quota error ("Free usage limit reached" in an ERROR line); any other failure is exit 1 as before. Every model out of quota is exit 4: the workflow skips green with a notice and posts no comment. The comment names the model that wrote it and, after a fallback, which models were out of quota. The allowlist is deepseek-v4.1-flash-free and glm-5.3-flash-free only: longcat-2.5-preview-free is no longer in the Zen docs (also dropped from `scripts/opencode-behaviour.py`). Tests: first model works, first out of quota and second works, all out of quota, a non-quota error not retried, a bad model anywhere in the list refused before any call, the workflow's exit-4 handling.

## [1.8.0] — 2026-10-27

### Added
- A "parked" status (card 01-179): `backlog/parked/` holds cards that are wanted but deliberately not now. The folder is the status (no `parked:` field); it is optional and made by the first card parked in a hub, so no hub needs migrating (minor, not major). workai-backlog has a Parking section (park and unpark by `mv`, a dated Notes line, a card depending on a parked card is blocked, `notes/parked.md` lists in hubs stay until picked up and then become cards); workai-structure, open-project, list-projects, board and the hub template name it. `report.py` reads `parked/`: flag `parked`, never claimable, blocked, stale, due or ungrouped; a Next entry for it is stale (`status: parked`); the hub report has a `parked (N)` section, `--list` a `parked (N): ids` line, `--waiting` a last `parked, not now` section, `--card` says `parked`. workai-board has a sixth column, parked, last. youtrack-sync maps parked to State Parked (added to H01's "Workai states" bundle on 2026-10-27), never Next, and falls back to Todo in a project whose State field has no Parked value or cannot be read; a group's State ranks Parked after Todo. Tests in test-report.sh, tools/workai-board/tests/test_parked.py and the sync tests.
- Standard CI (card 01-085): reusable `.github/workflows/outcome-ci.yml` (`workflow_call`; inputs `python`, `shell`, `shellcheck-severity`, `typecheck` off/report/enforce, `test-command`, `skip`): ruff 0.14.0, shellcheck 0.11.0 via shellcheck-py (`*.sh` and files with a sh/bash shebang, judged by basename; findings as annotations; a broken `skip` regex fails the job), basedpyright 1.31.6, the repo's tests; contents: read only, no secrets, pinned actions, inputs passed through `env:`. This repo calls it from `.github/workflows/ci.yml` on every PR and push to main. `scripts/run-tests.sh` runs the whole suite (tests/test-*.sh, the workai-board pytest via uv, check-skills.py). The test command runs under `bash -e -o pipefail`; typecheck `report` forgives only basedpyright's exit 1 (type errors), not a failed install or bad config. `ruff.toml` (ignores E741, E702), `pyrightconfig.json` (standard mode); lint fixes: an f-string without placeholders, `deps/lib.sh` shell directive, a glob test in `tests/test-new-project.sh`; the suite runs on Linux too (`test-install-deps.sh` runs the macOS route with `WORKAI_OS=Darwin`, `test-install-settings.sh` forces the keychain backend for its fake `security`; the CI test job sets a git identity). `tests/test-ci.sh`.

### Security
- AI PR review keeps `OPENCODE_API_KEY` out of the model's reach (card 01-157): `scripts/opencode-review.sh` starts a local key proxy (127.0.0.1, random port; key and token passed on stdin, never argv or environment; non-dumpable on Linux; accepts only callers with a random per-run token; forwards only plain, undecoded `/zen/...` paths to https://opencode.ai, replacing the Authorization header with the real key, streaming the answer back) and points the copy's opencode config at it with that token; opencode always runs with the key removed from its environment. With `AI_REVIEW_USER` (set by `ai-review.yml`, which creates the system user `aireview`) opencode runs via `sudo -n -u` as that user with a minimal environment (PATH, LANG, HOME/XDG inside the temp dir), so it cannot read the key from `/proc/*/environ` of the script or the proxy, nor the runner's private files (its own temp folders are 700, the proxy's files 600). Without `AI_REVIEW_USER` (macOS, by hand) opencode shares the caller's uid. The output guard also catches URL-safe base64 and hex (any case). `tests/test-ai-review.sh`: a fake upstream and a probing fake opencode prove the key is not in opencode's own environment or config, that the proxy adds it upstream and refuses other paths and callers; on Linux CI, as another user, that it is in no environment opencode can read (`/proc/*/environ`, `ps`), with a control showing that as the same user the probe does find it there, so `/proc` isolation depends on `AI_REVIEW_USER`.

### Changed
- YouTrack project short names carry the hub number (card 01-158, decided in 01-149): hub 01's project is `H01` (was `WP`; YouTrack keeps `WP-N` as aliases). The sync treats an old group id as an alias of the issue's current id, so a card still naming `WP-N` is linked to `H01-N` once and then left alone (found by the AI review). Examples in the youtrack-sync README and docstring, the workai-backlog card format and the sync/report tests say `H01-N`.
- YouTrack boards (card 01-159, decided in 01-149): one "NN Groups" per hub and one cross-hub "All Cards" board (was "01 Cards", renamed in place, so its issues stay); a joining hub adds its project to "All Cards". No sync code change: new card issues already go on boards ending in "Cards".

### Fixed
- youtrack-sync reads card frontmatter with report.py's parser (the one workai-board shows), instead of its own copy: `\"` inside a double-quoted title is unescaped (card 01-159's title reached YouTrack as `\"All Cards\"`) and a ` #` inside quotes no longer cuts the title (AI review of PR #7). report.py (and so workai-board) also reads single-quoted values, `''` as `'`, so `youtrack: 'H01-1'` is a group, not a bad id.

## [1.7.0] — 2026-10-26

### Fixed
- AI PR review hardening from its first real review (card 01-084): the step holding `OPENCODE_API_KEY` runs `scripts/opencode-review.sh` taken from the base commit (`git show $BASE_SHA:...`), never the PR head's copy; the diff ignores the PR's `.gitattributes` diff settings (`* !diff` in `info/attributes`, `--no-ext-diff --no-textconv`; real binaries stay one line); the agent's copy is written straight from HEAD's blobs (no `.gitattributes` rule applies: `export-ignore` cannot hide files, no smudge filter runs; symlinks and submodules skipped); the comment names the reviewed head and time; opencode runs with a throwaway HOME/XDG and, on macOS, under `sandbox-exec` denying the real HOME (except the folder of the opencode binary, if installed there); the agent's config also denies `external_directory` explicitly, and a review whose text contains `OPENCODE_API_KEY` (plain or base64) is never written (exit 1); models outside the zero-retention allowlist (deepseek-v4.1-flash-free, glm-5.3-flash-free, longcat-2.5-preview-free) exit 2; every non-blank text part of the model's last step is posted, not just the last one (whitespace only counts as no text: exit 1); the workflow also runs on `synchronize` and updates its newest comment (marker `<!-- ai-review:opencode -->`) and deletes older ones instead of adding new ones. Job timeout 15 -> 30 min (two reviews hit 15). workai-structure's History rule names the workai-playbooks PR rebase-merge exception; workai-backlog's PR cleanup says how to delete the local branch after a rebase merge.

## [1.6.0] — 2026-10-25

### Added
- `scripts/clean-machine-test.sh mac-vm` (card 01-019): a clean macOS target. Clones the local tart VM `workai-clean-mac` (cirruslabs vanilla, no Homebrew) to a throwaway `workai-cmt-*`, boots it headless, ssh with the image's default password via `SSH_ASKPASS` (no key, agent or ssh config of this Mac), copies the checkout in and runs 12 steps: `deps/install-mac.sh --check` fails, no package manager is reported, Homebrew installs, `--dry-run`, install, skills/settings/MCP/CLAUDE.md, `--check`, second run only `ok` + "tools: nothing missing" and no file or formula changed, uninstall, all gone. Refuses below 40 GB free or while another throwaway clone exists; stops and deletes the clone on any exit. Only when named.

### Changed
- `~/.claude/CLAUDE.md` belongs to the user (card 01-155, reverses 01-152's link): `install.sh claude` never touches an existing one (a file or any other symlink: `kept`) and only copies the new generic `claude/CLAUDE.md.template` there as a plain file when it is missing, recorded with its sha256; `--check` reports `missing`/`kept`/`ours`; `--uninstall` removes it only while byte-identical to what was written. The 152 link into a checkout or release of this repo is replaced by a plain file with the target's content (`migrated`; from the tag or git history when the target is gone, also for a deleted checkout known by the 152 manifest entry); `--uninstall` of a never-migrated 152 link still removes it and restores its backup. The personal `claude/CLAUDE.md` is removed from the repo. README and the workai-structure skill say to edit `~/.claude/CLAUDE.md` itself. `tests/test-install-claude-md.sh` rewritten.
- Opening a hub by name (card 01-154): `report.py NAME` and workai-open-project also match the folder names in a hub's `repos/` and the words of an optional README line `<!-- aliases: word, word -->` (lookup only; `--index` and `--list` unchanged), and an archived hub titled `(merged into NN — ...)` gives way to hub NN when both match; an archived hub that is the only match still opens, ARCHIVED. New fixture `fixture_merged_hubs`; tests in test-find-list.sh and test-report.sh.

### Fixed
- `deps/install-mac.sh` on a fresh Homebrew (found by the mac-vm run, card 01-019): Homebrew 7 refuses formulae from an untrusted tap, so `brew bundle` failed on `raine/workmux/workmux`; it now runs `brew trust --formula` for the tap formulae in the Brewfile (only those, only when brew has `trust`). Python is the `python` formula instead of `python@3.13`, which Homebrew no longer links as `python3` once it is not the default, so python3 stayed missing.

## [1.5.0] — 2026-10-25

### Added
- `scripts/clean-machine-test.sh [--break] [TARGET...]` (card 01-019): installs a copy of the checkout in a new `ubuntu:24.04` / `ubuntu:26.04` container (deps `--check`, `--dry-run`, first run without `~/.local/bin` on PATH, install, `--check`, second run prints only `ok` lines and changes no file or package, `install.sh claude --uninstall`, everything gone) and in a throwaway HOME on this Mac (`mac-home`, fake `claude`); PASS/FAIL per step, a target fails when a step fails or not every step ran. `--break` makes install.sh claim skills linked without linking them, and the run fails. Slow, so `tests/test-clean-machine.sh` runs it only with `WORKAI_CLEAN_MACHINE=1`.
- `scripts/opencode-behaviour.py` (card 01-153): scripted behaviour test of the skills in opencode with a free zero-retention model (deepseek-v4.1-flash-free; glm/longcat allowed, every other model refused) on the eval fixture: cases open-project, waiting-on-me, card-status and a canary case; PASS/FAIL per case, exit 1 on failure; fake HOME/XDG/WORKAI_ROOT, opencode.json denials, no `--auto`, `sandbox-exec` denying the real home on macOS, and a canary token in the real `~/workai` that must never appear. `--break <skill>` proves a sabotaged skill fails. `tests/test-opencode-behaviour.sh` runs the model-free parts (self-test, dry run); model runs only with `WORKAI_OPENCODE_TEST=1`.
- AI review of pull requests (card 01-084 pilot): `.github/workflows/ai-review.yml` runs `scripts/opencode-review.sh`, which reviews the PR diff with opencode 2.1.3 (pinned tarball, SHA-256 checked) and the zero-retention free model `deepseek-v4.1-flash-free`, as a read-only agent on a copy of the PR head, and posts one comment. `pull_request` only, same-repo branches, `GITHUB_TOKEN` only, actions pinned to SHAs; skips green with a notice while the repository secret `OPENCODE_API_KEY` is missing. workai-backlog's finishing steps say how a workai-playbooks card is merged through a PR (`gh pr merge --rebase`). `tests/test-ai-review.sh`.

## [1.4.1] — 2026-10-25

### Changed
- `claude/CLAUDE.md` says where to edit it: the repo file, then release and install (the live file is a link into a release).

## [1.4.0] — 2026-10-25

### Added
- `tools/workai-board/launchagent.sh install|uninstall|status|plist [--port N]` (card 01-150): runs `workai-board --web` as the macOS LaunchAgent `com.bartek.workai-board-web` (RunAtLoad + KeepAlive, log `~/Library/Logs/workai-board-web.log`), so the phone URL survives a reboot; plist written from the repo, idempotent, Mac only, refuses a card worktree. `tests/test-board-launchagent.sh` (fake launchctl).
- The repo owns the global rules (card 01-152): `claude/CLAUDE.md` is today's `~/.claude/CLAUDE.md`; `install.sh claude` (new part `claudemd`, `--claude-md-only`) symlinks `~/.claude/CLAUDE.md` to it, backing up an existing file (without `--force` only an identical one; a different one is refused with a diff), records the backup in the manifest, and `--uninstall` restores it; `--check` reports a missing link or a differing file. The workai-structure skill says to edit the repo file. `tests/test-install-claude-md.sh`.

### Changed
- Skills agent-neutral for opencode (card 01-140, from the 075 trial): `report.py` honours the `WORKAI_ROOT` environment variable in every mode (a positional root still wins; empty means `~/workai`), so a test can point it at a fixture instead of the real workai. workai-open-project says "use absolute paths" instead of "change the working directory" and gains an "Asking" rule: with no way to ask (headless), end with the question as text and stop; workai-structure's agent rules, archive-project and new-project say the same. Tests in test-report.sh.
- The workai index is regenerated, never hand-edited (card 01-151): new `skills/workai-open-project/regen-index.sh` rewrites `~/workai/CLAUDE.md` with `report.py --index` and commits it with `.gitignore` (those two paths only) under the shared-file lock (reused when this session or `WORKAI_LOCK_OWNER` holds it, else taken and released). `new-project.sh`, `migrate.sh` and `archive.sh` (and `--restore`) call it and no longer write `## NN` sections; they exit 1 with a warning if it fails. The new-project, migrate, archive, open-project and structure skills and the new-project eval describe the index as generated. Tests in test-new-project.sh, test-migrate.sh, test-archive.sh.

## [1.3.0] — 2026-10-25

### Changed
- Push policy in force (card 01-108, the user 2026-10-25): agents push private hubs, the workai root and private outcome repos after each finished card through the scanning pre-push hook; public repos, deploying pushes and local-only hubs need his OK. Written in workai-structure "Git and concurrency"; workai-backlog (finishing step 4, Next), new-project and migrate point to it. The workai index is named as generated there.

## [1.2.0] — 2026-10-25

### Added
- Pre-push scan everywhere (card 01-141): `add-repo.sh` and `migrate.sh` install the hook in every new or moved-in outcome repo; `install-scan-hook.sh` chains in front of Git LFS's own pre-push hook instead of refusing it. It refuses a hooks folder inside the work tree (`core.hooksPath` to a tracked folder) instead of leaving untracked copies there; this repo tracks its own `.githooks/pre-push`. Tests in test-scan.sh, test-new-project.sh, test-migrate.sh.
- `tools/youtrack-sync` (card 01-116): each card with `youtrack:` becomes a subtask (`NN-NNN <title>`, Type Task) of its group issue, State from its folder (Waiting when `waiting:` is filled, Next when in next.md); the group gets its busiest card's State; new issues go on the project's boards; one way, idempotent, token via `workai-secret`. `tests/test-youtrack-sync.sh`.
- Card groups (card 01-147): `youtrack: <issue id>` on a card names its group, a larger YouTrack issue. `report.py` adds the `youtrack` field and the `ungrouped` flag (an open card without a group in a hub where some card has one) and prints `without a group (no youtrack:)` in the hub report and `group: <id> (YouTrack)` in `--card`; the workai-backlog skill and the card template carry the rule. `tests/test-report.sh`.
- `workai-secret` (card 01-146): `set/get/list/rm/run/export-systemd/backend` over the macOS keychain, `secret-tool` or `pass`, values never in argv (keychain written through `security -i` as hex), `run` exports secrets as env vars (names from `env-map`), `export-systemd` encrypts one for a unit with `systemd-creds`. `install.sh claude` links `tools/workai-*/<name>` into `~/.local/bin` (new part `tools`, `--tools-only`, `WORKAI_BIN_DIR`). The YouTrack MCP wrapper reads `youtrack/api` through it. `tests/test-workai-secret.sh` (fake backends, canary check); real runs on macOS and Ubuntu 24.04 with `pass`.
- `install.sh claude` sets up settings and MCP servers too (card 01-006): merges `claude/settings.fragment.json` (+ `settings.fragment.darwin.json` on macOS) into `~/.claude/settings.json` with jq (objects key by key, arrays unioned, nothing removed, differing values reported, timestamped backup, written only on change), records what it added in `~/.claude/workai-installed.json` for `--uninstall`, and adds the MCP servers of `claude/mcp.json` with `claude mcp add --scope user`, guarded by `claude mcp get`. New `--settings-only` and `--skills-only`. Contents: `tui: fullscreen`, `skipWorkflowUsageWarning`, Mac soft_deny `Bash(tmutil delete:*)`, and the `youtrack` MCP server (local YouTrack Server via `claude/mcp/youtrack-mcp.sh`: keychain token, pinned `mcp-remote@0.14.3`, token never in a config file or on a command line). `tests/test-install-settings.sh`.
- `workai-board --web [--port N]` (card 01-142): the board as a read-only HTML page on 127.0.0.1 (default port 8646), same columns, order, card lines and project looks as the TUI (column logic now shared in `app.column_cards`); GET/HEAD `/` only, `Cache-Control: no-store`, no JavaScript or external assets, standard library server. Phone access through `tailscale serve --bg 8646` (README).
- `workai-board` narrow mode (card 01-082): below 100 terminal columns one column at a time, full width, header `< doing (2) >`, `h`/`l` switch; automatic on resize, `n` forces it.

### Fixed
- New hubs and outcome repos start on branch `main` (card 01-145): `new-project.sh` and `add-repo.sh` run `git init -b main` instead of taking git's default, which is `master` on a machine without `init.defaultBranch` (hub 43 was created on `master` from release v1.1.0 and renamed by hand). `tests/test-new-project.sh` forces `init.defaultBranch=master` to check it.

### Removed
- `tools/kanboard-sync`: Kanboard was dropped for YouTrack (cards 117, 144); replaced by `tools/youtrack-sync`.

## [1.1.0] — 2026-10-24

### Added
- Skill `workai-new-project`: `new-project.sh` creates a numbered hub; `add-repo.sh` adds an outcome repo with the workmux setting; tests.
- Behaviour evals: `scripts/run-evals.sh`, four cases with a fake workai fixture, plugin manifest for `claude plugin eval`.
- Skill `workai-migrate`: `migrate.sh` (old-style project to hub, with dry run) and `find-refs.py` (everything pointing at a path); tests.
- Skill `workai-archive-project`: `archive.sh` moves a hub to `archives/` and back, refusing while work is in progress; tests.
- `workai-open-project/report.py --json` (one hub or `--all`, `--archives`, `--git`): every card with fields, body, dependents and computed flags; `tests/test-report.sh`.
- `tools/workai-board`: read-only Textual board of every hub's backlog (columns, h/j/k/l, auto-refresh), kanban-md look with its MIT notice; Pilot tests.
- `workai-board` card detail: fields, markdown body, scrolling, `E` opens `$VISUAL`/`$EDITOR`/`vi`.
- `workai-board` search (`/`: title words, `#01-009`, `#009`, `@01`) and sort (`s` priority/id/finished/project, `S` reverse).
- `workai-board` dependency navigation: related cards in the detail view, `Tab`/`Enter` to follow, `Esc` back one step, `q` to the board.
- `workai-board --tmux`: starts the board in a detached tmux session `workai-board` (reused if running) and prints `tmux attach -t workai-board`.

- Next: a global, ordered list of at most 5 todo cards in `~/workai/next.md` (`01-092  # reason`). `report.py --json` gains `next` (order, shown, stale ids, warnings) and a `next` place per card, the text report puts Next first in the picking order; `workai-board` shows a Next column between todo and doing (file order, not repeated in todo, stale ids hidden, warnings in the status bar); the workai-backlog skill has the new picking order (Next beats priority on purpose), the next.md rules and a "plan next" procedure.

- "What's waiting on me" (card 01-090): `workai-board` gains a Waiting column (doing/ cards with `waiting:` filled; columns todo · next · doing · waiting · done), shows the waiting text in full on its own line, sinks and dims dependency-blocked todo cards below the claimable ones (`B` hides / shows them), and the detail view gives each related card's state plus a `Blocked by` field. `report.py --waiting`: waiting cards across active hubs (question, last Notes item, card file), then stale cards, then todo cards blocked only by waiting ones; the workai-list-projects skill runs it for "what's waiting on me".

- Pre-push scan (card 01-105): `workai-new-project/scan.py` checks a repo's whole history for secrets (private keys, GitHub/Google/AWS/Anthropic/OpenAI/Slack/Stripe tokens, passwords in URLs and assignments, credential files such as `.p12`/`.env`/`id_ed25519`) and identity documents (DNI/passport/birth-certificate/signature scans by file name, Spanish DNI/NIE numbers with a valid control letter); runs gitleaks too when installed; never prints values. `push-hub.sh` scans, then pushes to a private repo, and stops on a hit; `install-scan-hook.sh` adds a pre-push hook, which `new-project.sh` installs in every new hub; `migrate.sh` prints the scan result. The new-project and migrate skills push only through `push-hub.sh`. `.workai-scan-allow` lists accepted false positives. `tests/test-scan.sh`.
- `report.py` robustness (card 01-112): an unreadable card (dangling symlink, vanished mid-scan, a directory) is skipped with a warning and non-UTF-8 bytes are replaced with a warning, instead of killing every mode and the board; two cards with the same id are both kept, flagged `duplicate` and warned about; `depends:` strips ` # comments`, reads block-style lists, rejects cross-hub labels like `02-001` (invalid, blocking) and flags self-dependencies and cycles (`cycle`, `dep_problems`); one `prio()` parser (`2 # normal`, `high`/`normal`/`low`, anything else None with a warning); the text report and `--list` use the JSON flags; when git fails on a card's branch the card is `activity_unknown`, never STALE. JSON gains top-level `warnings` (also on stderr in every mode); `workai-board` shows them in the status bar and marks invalid dependencies.

- `due:` (card 01-107): cards accept `due: YYYY-MM-DD` for real deadlines. `report.py` gives `due`, `due_in_days` and flags `due_soon` (open card due within 14 days) / `past_due`; `--waiting` opens with "due within 14 days or past due" (soonest first, `PAST DUE` marked), `--list` and the hub report show them too; `workai-board` puts them on top of their column (blocked or not, never hidden by `B`), shows the date on the card (orange soon, red past/today) and a Due row in the detail view. The workai-backlog skill and the card template document the field.
- Releases instead of live links (card 01-110): `install.sh claude --release [vA.B.C]` links the skills into a locked, detached release worktree of the tag (`~/.local/share/workai-playbooks/releases/<tag>`), so a merge to main no longer changes every session; `scripts/release.sh a.b.c` cuts a release (CHANGELOG entry, VERSION, commit, tag; no push; at least a minor bump when a SKILL.md changed) and `--check` says when one is due; the open-project report prints `playbooks: <version> (release vX | live checkout, N commits after vX)`. `tests/test-install-release.sh`.

- Waiting cards (card 01-109): the workai-backlog skill requires the question in full in the card's Notes (never "in the main session"), a `waiting_since:` date, and forbids finishing a card whose Done-when check is owed elsewhere. `report.py` gives `waiting_days` and flag `waiting_old` (waiting more than 7 days since `waiting_since:`, else `started:`), shown by `--waiting` ("OLD: ask again or release"), the hub report and the board (`WAIT OLD 10d`). The card template gains `waiting_since:`.
- Mac install of the tools (card 01-018): `deps/install-mac.sh` (`--check`, `--dry-run`, `--brewfile`, `--release`) installs the missing tools of `deps/tools.txt` with Homebrew (`brew bundle --no-upgrade`) or MacPorts (ports, pinned release binaries with SHA-256 from `deps/release-binaries.txt`, Claude Code's native installer), then the skills; `tests/test-install-deps.sh`.
- Ubuntu install of the tools (card 01-021): `deps/install-ubuntu.sh` (`--check`, `--dry-run`, `--release`), same `deps/tools.txt`: apt packages, gh and Claude Code from their vendor apt repositories (Claude Code key fingerprint checked), workmux and gitleaks as pinned release binaries, then the skills.

- "Status of card NNN" (card 01-091): `report.py --card NN-NNN|NNN` shows one card from any hub, active or archived (project, status line with holder/WAITING/STALE/blocked, due, dependencies, last Notes items); a bare id means the hub the current directory is in, else matches in several hubs are listed (exit 3), none exits 2. The workai-open-project skill answers "status of card 042" with it; eval case `card-status` (not run yet, card 01-072).

- find-refs, titles, triggers (card 01-115): `find-refs.py` also scans `~/.claude/MEMORY.md`, `~/.claude/CLAUDE.md`, Claude settings (hooks and permission rules; location only, the line is never printed since rules have held secrets) and shell rc files (overrides `CLAUDE_DIR`, `RC_FILES`), and counts a path followed by a full stop (`projects/ceramics.`) while `projects/ceramics.md` stays another path; `tests/test-find-refs.sh`. `new-project.sh` validates the title first (one line, printable, no leading `#`, at most 80 characters), fills the templates in one pass (a title with `DATE` or `NN` stays as typed) and removes a half-made hub when it fails before the first commit. Skill descriptions: workai-structure no longer competes for "open project N"; workai-backlog covers "plan next" / "what next" and defines the main agent.

- Compact index (card 01-106): `report.py --index` generates the workai index (fixed header on the current structure, one line per hub, active then archived, by number; goal from a README `<!-- index: ... -->` line or the scrubbed first Goal sentence: parentheses, plates, NIE/DNI, phones, emails, IBANs removed). `scripts/split-index.py [--write]` saves each entry of the old hand-kept index into its hub's notes before a switch. Not yet live: replacing `~/workai/CLAUDE.md` waits on the user.

- Git and concurrency policy (card 01-108): a section in the workai-structure skill (claims by `mv` on the hub's main only, commits of your own paths only, ids and hub numbers on main under the lock, draft cards as `draft-<slug>.md`, no amend/rebase/reset on a shared main, what may be committed and pushed without asking, remotes), referenced from the backlog, new-project and migrate skills; routine pushing of private hubs is written as a proposal pending the user. `scripts/check-skills.py --cards [WORKAI_ROOT]` fails on two cards with the same id in one hub.

### Changed
- `install.sh` no longer takes the links over from another existing checkout (second clone, worktree, or live checkout -> release) without `--force`, and no longer deletes another checkout's extra skills as orphans; it warns when run from a linked worktree.
- `workai-board` look: each project's cards have their own border, one of 8 colours (validated on light and dark backgrounds, colour-blind safe) x 4 border styles (round, double, heavy, dashed) = 32 looks, stored in `<workai>/.workai-board/colours.json` (hand-editable; a project keeps its look for good). Blocked / WAIT lose the red border and show `BLOCKED` / `WAIT` as text; the selected card gets a background tint and a `▶` marker; the detail view shows the project's border. Priority shows as `priority: high|normal|low` on the card's second line and in the detail view instead of `p1`/`p2`/`p3` (card files keep `priority: 1|2|3`).
- Skill `workai-list-projects` and `report.py --list [active|archived|all]`: one line per hub with its goal, cards in doing/ with WAITING/STALE, and uncommitted or unpushed work.
- `workai-open-project` opens a project by name or fragment ("my music", case and accents ignored) or old number ("L38", through the hub's "old number" note); several matches list the candidates (exit 3), none fails (exit 2), never a guess. `tests/test-find-list.sh`; eval cases `list-projects` and `open-project-by-name`; `fixture_more_hubs` in the eval fixture.

### Changed
- `find-refs.py`: one pass for all paths (about 1.5 s instead of a minute per path); skips logs, binaries and data files.
- Migrate, new-project and archive skills: shared-file lock for parallel agents; private GitHub hub repos by default; migration fills the hub README from the old entry and adds a card for plan files.
- `run-evals.sh` always uses the claude.ai subscription, never an API key.
- `workai-new-project`: `NO_REGISTER=1` to skip workai registration.
- `workai-structure`: old project numbers carry an `L` prefix (`L38`).

## [1.0.0] — 2026-10-24

First structure version: numbered project hubs (`projects/NN-name/`) with
`backlog/`, `repos/`, `worktrees/` and a `STRUCTURE` file.

### Migration
- From 0 (old-style project: a plain repo or `.md` plan in `projects/`):
  convert to a hub as described by the `workai-structure` skill. The
  `workai-migrate` skill (planned) will automate this; until then, only by
  hand and only when the user asks.
- Hubs created before this release (01-workai-playbooks): add a `STRUCTURE`
  file containing `1.0.0`.

### Added
- README: repo layout and agent-neutral skill format rules; empty `skills/`.
- Skill `workai-structure`: workai layout, hubs, numbering, structure versions (`STRUCTURE` file per hub).
- Skill `workai-backlog`: card format, picking, claiming, worktrees, waiting, finishing, archiving, stale claims.
- `scripts/check-skills.py` static skill checks, its tests, optional pre-commit hook.
- Skill `workai-open-project` ("work on project N") with a read-only `report.py`.
- `install.sh claude` with `--check` and `--uninstall`, and its tests.
- README: which agents read SKILL.md and where, with sources; name/description limits.

## [0.1.0] — 2026-10-24

### Added
- `VERSION`, this changelog, release tags.
