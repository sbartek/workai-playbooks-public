#!/usr/bin/env bash
# Behaviour evals: run each skill's cases through Claude Code headless against
# a fake ~/workai built by evals/_fixtures/workai.sh. Uses quota: run on demand
# and before a release, not on every commit.
#
#   scripts/run-evals.sh                 all cases, 3 runs each
#   scripts/run-evals.sh --runs 1        quick pass
#   scripts/run-evals.sh --case 'open*'  one case
# Extra arguments go to `claude plugin eval`. Add `--ablation with-without`
# to also run without the skills and see what they add.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
# Always use the claude.ai subscription: an exported API key would make Claude
# Code bill the key instead. Drop it, then refuse unless the login is claude.ai.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
auth="$(env -u CLAUDECODE claude auth status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authMethod",""))' 2>/dev/null || true)"
if [ "$auth" != "claude.ai" ]; then
  echo "refusing to run evals: Claude Code auth is '${auth:-unknown}', not the claude.ai subscription" >&2
  exit 3
fi
# Inside a run the permission mode is dontAsk: a Bash command runs only if every
# part of it matches a granted tool (below, and the case's allowed_tools); a chained
# `python3 x; echo $?` or `cd d && git ...` is denied. And the run's sandbox
# denies Apple's git: its git-credential-store/-cache are symlinks to the git
# binary, which the sandbox's credential-helper list therefore blocks, and the
# /usr/bin/git shim cannot write its xcrun cache. Warn when that is the git
# on PATH: cases that grade git state will then fail (README, card 072).
if [ "$(command -v git)" = /usr/bin/git ]; then
  echo "warning: git on PATH is Apple's /usr/bin/git, which eval runs cannot execute; install another git earlier on PATH (e.g. brew install git)" >&2
fi
exec env -u CLAUDECODE claude plugin eval . \
  --scaffold --trust-plugin --no-publish --ablation none --judge-model sonnet \
  --allow-tools "Bash(python3:*)" "Bash(cd:*)" "Bash(git:*)" "Bash(mv:*)" \
    "Bash(ls:*)" "Bash(date:*)" "Bash(bash:*)" "Bash(cat:*)" Edit \
  "$@"
