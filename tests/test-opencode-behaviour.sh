#!/usr/bin/env bash
# scripts/opencode-behaviour.py (card 01-153). Always: the scorer on canned
# transcripts and the sandbox dry run (no model calls). The real opencode
# runs cost free-model calls and need the network: only with
# WORKAI_OPENCODE_TEST=1, which also checks that a broken skill fails.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/scripts/opencode-behaviour.py"
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

python3 "$script" --self-test >/dev/null && pass "scorer self-test" || fail "scorer self-test"
python3 "$script" --model big-pickle --dry-run >/dev/null 2>&1
[ $? -eq 2 ] && pass "a non-zero-retention model is refused" || fail "big-pickle not refused"
python3 "$script" --dry-run && pass "sandbox dry run" || fail "sandbox dry run"

if [ "${WORKAI_OPENCODE_TEST:-}" = 1 ]; then
  python3 "$script" && pass "opencode cases" || fail "opencode cases"
  python3 "$script" --break workai-open-project --case open-project
  [ $? -eq 1 ] && pass "broken skill fails its case" || fail "broken skill did not fail"
else
  echo "skip opencode model runs (set WORKAI_OPENCODE_TEST=1)"
fi
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
