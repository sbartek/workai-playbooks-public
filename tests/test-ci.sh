#!/usr/bin/env bash
# Tests for the standard CI (card 01-085): the reusable workflow
# .github/workflows/outcome-ci.yml, its caller ci.yml and scripts/run-tests.sh.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
wf="$here/.github/workflows/outcome-ci.yml"
caller="$here/.github/workflows/ci.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -f "$tmp/out" ] && sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

check "reusable workflow exists" '[ -f "$wf" ] && grep -q "^  workflow_call:" "$wf"'
check "workflow_call is its only trigger" '[ "$(sed -n "/^on:/,/^[a-z]/p" "$wf" | grep -cE "^  [a-z_]+:$")" = 1 ]'
check "top-level permissions are empty" 'grep -q "^permissions: {}" "$wf" && grep -q "^permissions: {}" "$caller"'
check "jobs only read contents" '! grep -Eq "(contents|pull-requests|issues|actions|id-token|packages): write" "$wf" "$caller"'
check "no secrets in the CI" '! grep -v "^ *#" "$wf" "$caller" | grep -q "secrets\."'
uses="$(grep -E '^\s*(- )?uses: [^.]' "$wf" | sed -E 's/.*uses: *//; s/ .*//')"
check "every action pinned to a full commit SHA" '[ -n "$uses" ] && ! printf "%s\n" "$uses" | grep -Ev "@[0-9a-f]{40}$"'
check "checkout keeps no credentials" '[ "$(grep -c "persist-credentials: false" "$wf")" = "$(grep -c "uses: actions/checkout@" "$wf")" ]'
check "tool versions pinned" 'grep -Eq "RUFF_VERSION: [0-9]+\.[0-9]+\.[0-9]+" "$wf" && grep -Eq "BASEDPYRIGHT_VERSION: [0-9]+\.[0-9]+\.[0-9]+" "$wf" && grep -Eq "SHELLCHECK_PY_VERSION: [0-9]+(\.[0-9]+){2,3}" "$wf" && grep -q "pipx install \"shellcheck-py==\$SHELLCHECK_PY_VERSION\"" "$wf"'
# --- the file-listing step, run as bash -----------------------------------
list="$(awk '/- name: List the files to lint/{f=1} f&&/run: \|/{g=1;next} g&&/^      - name:/{exit} g' "$wf" | sed 's/^          //')"
l="$tmp/lrepo"; mkdir -p "$l/.hooks" "$l/a.b" "$l/vendor"; git -C "$l" init -q
printf '#!/bin/sh\n' >"$l/.hooks/pre-push"; printf '#!/usr/bin/env bash\n' >"$l/a.b/tool"
printf 'x\n' >"$l/a.b/notes.txt"; printf 'echo\n' >"$l/x.sh"; printf 'echo\n' >"$l/vendor/v.sh"; printf 'pass\n' >"$l/m.py"
git -C "$l" add -A
run_list() { mkdir -p "$tmp/lrt"; (cd "$l" && RUNNER_TEMP="$tmp/lrt" SKIP="$1" bash -e -o pipefail -c "$list") >"$tmp/out" 2>&1; }
run_list '^vendor/'
check "lint list: shebang scripts in dotted folders count, other extensions do not, skip works" '[ $? = 0 ] && [ "$(tr "\0" "\n" <"$tmp/lrt/sh" | sort | tr "\n" " ")" = ".hooks/pre-push a.b/tool x.sh " ] && [ "$(tr "\0" "\n" <"$tmp/lrt/py")" = "m.py" ]'
run_list '('
check "lint list: a broken skip regex fails the step" '[ $? != 0 ] && grep -q "not a valid extended regex" "$tmp/out"'

# Inputs go through env:, never pasted into a script (injection).
runs="$(awk '/run: \|/{f=1;next} f&&/^      - |^  [a-z]/{f=0} f' "$wf"; grep -E '^\s+run: [^|]' "$wf")"
check "inputs reach run scripts only through env" '! printf "%s\n" "$runs" | grep -q "{{ *inputs\."'
check "caller uses the local reusable workflow" 'grep -q "uses: ./.github/workflows/outcome-ci.yml" "$caller"'
check "caller runs the suite" 'grep -Eq "test-command: .*scripts/run-tests.sh$" "$caller"'
check "test command runs with -e and pipefail" 'grep -q "run: bash -e -o pipefail -c \"\$TEST_COMMAND\"" "$wf"'
check "report mode forgives only exit 1 of basedpyright" 'grep -q "if \[ \"\$rc\" = 1 \] && \[ \"\$MODE\" = report \]" "$wf" && grep -q "pipx install \"basedpyright==\$BASEDPYRIGHT_VERSION\"" "$wf"'
if command -v ruby >/dev/null 2>&1; then
  check "workflows are valid YAML" 'ruby -ryaml -e "ARGV.each { |f| YAML.load_file(f) }" "$wf" "$caller" >"$tmp/out" 2>&1'
fi

# --- the shellcheck annotation line, run as sed ----------------------------
sedexpr="$(grep -E "^ *sed -E 's/\^\(\[\^:\]\+\)" "$wf" | sed -E "s/^ *sed -E //; s/ \"\\\$RUNNER_TEMP\/sc.out\"$//")"
printf '%s\n' "a.sh:3:5: error: bad thing [SC2144]" "b.sh:1:1: note: tip [SC2086]" >"$tmp/sc.out"
eval "sed -E $sedexpr \"\$tmp/sc.out\"" >"$tmp/out" 2>&1
check "shellcheck findings become annotations" 'grep -qx "::error file=a.sh,line=3,col=5::bad thing \[SC2144\]" "$tmp/out" && grep -qx "::notice file=b.sh,line=1,col=1::tip \[SC2086\]" "$tmp/out"'

# --- run-tests.sh on a fake repo --------------------------------------------
r="$tmp/repo"; mkdir -p "$r/tests" "$r/scripts"
cp "$here/scripts/run-tests.sh" "$r/scripts/"
echo "pass" >"$r/scripts/check-skills.py"
echo "exit 0" >"$r/tests/test-good.sh"
echo "exit 1" >"$r/tests/test-broken.sh"
bash "$r/scripts/run-tests.sh" >"$tmp/out" 2>&1
check "run-tests: one failing test fails the run" '[ $? = 1 ] && grep -q "FAIL test-broken" "$tmp/out" && grep -q "pass test-good" "$tmp/out"'
SKIP_TESTS='^test-broken$' bash "$r/scripts/run-tests.sh" >"$tmp/out" 2>&1
check "run-tests: SKIP_TESTS skips by name (anchored regex)" '[ $? = 0 ] && grep -q "skip test-broken" "$tmp/out" && grep -q "all passed" "$tmp/out"'
SKIP_TESTS='(' bash "$r/scripts/run-tests.sh" >"$tmp/out" 2>&1
check "run-tests: a broken SKIP_TESTS regex exits 2" '[ $? = 2 ] && grep -q "not a valid extended regex" "$tmp/out"'
echo "import sys; sys.exit(1)" >"$r/scripts/check-skills.py"
SKIP_TESTS=broken bash "$r/scripts/run-tests.sh" >"$tmp/out" 2>&1
check "run-tests: a failing check-skills fails the run" '[ $? = 1 ] && grep -q "FAIL check-skills" "$tmp/out"'

[ "$fails" = 0 ] && echo "all tests pass" || { echo "$fails failed"; exit 1; }
