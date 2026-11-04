#!/usr/bin/env bash
# Run the whole suite: every tests/test-*.sh, tools/workai-board's pytest
# (with uv; skipped with a note when uv is missing), then
# scripts/check-skills.py.
# Exit 1 if any of them fails. Used by CI (.github/workflows/ci.yml, card
# 01-085) and by hand before a push:
#
#   scripts/run-tests.sh            # all
#   SKIP_TESTS="clean-machine|board" scripts/run-tests.sh   # skip by regex on the name
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
skip="${SKIP_TESTS:-}"
if [ -n "$skip" ]; then
  rc=0; printf '' | grep -Eq -- "$skip" || rc=$?
  [ "$rc" -le 1 ] || { echo "run-tests: SKIP_TESTS is not a valid extended regex: $skip" >&2; exit 2; }
fi
failed=()
for t in "$here"/tests/test-*.sh; do
  name="$(basename "$t" .sh)"
  if [ -n "$skip" ] && printf '%s\n' "$name" | grep -Eq -- "$skip"; then
    echo "skip $name"
    continue
  fi
  echo "::group::$name"
  if bash "$t"; then
    echo "::endgroup::"
    echo "pass $name"
  else
    echo "::endgroup::"
    echo "FAIL $name"
    failed+=("$name")
  fi
done
if [ ! -d "$here/tools/workai-board/tests" ]; then
  :
elif [ -n "$skip" ] && printf '%s\n' workai-board | grep -Eq -- "$skip"; then
  echo "skip workai-board"
elif ! command -v uv >/dev/null 2>&1; then
  echo "skip workai-board (pytest needs uv)"
elif echo "::group::workai-board" && (cd "$here/tools/workai-board" && uv run --quiet pytest -q); then
  echo "::endgroup::"; echo "pass workai-board"
else
  echo "::endgroup::"; echo "FAIL workai-board"; failed+=(workai-board)
fi
if python3 "$here/scripts/check-skills.py"; then
  echo "pass check-skills"
else
  echo "FAIL check-skills"
  failed+=(check-skills)
fi
if [ "${#failed[@]}" -gt 0 ]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
echo "all passed"
