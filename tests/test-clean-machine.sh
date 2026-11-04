#!/usr/bin/env bash
# scripts/clean-machine-test.sh is slow (Docker, real apt, minutes per
# target), so the normal suite checks only that it parses and prints its
# help. WORKAI_CLEAN_MACHINE=1 runs it for real: every target must pass, and
# a --break run of mac-home must fail on "skills linked" (proof that the
# checks see a broken install). Pass targets in WORKAI_CLEAN_MACHINE_TARGETS
# (default: all).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
s="$here/scripts/clean-machine-test.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }

bash -n "$s" >"$tmp/out" 2>&1 && ok "clean-machine-test.sh parses" || bad "clean-machine-test.sh parses"
bash "$s" --help >"$tmp/out" 2>&1 && grep -q -- '--break' "$tmp/out" && ok "--help describes --break" || bad "--help describes --break"
bash "$s" --help >"$tmp/out" 2>&1 && grep -q 'mac-vm' "$tmp/out" && ok "--help describes mac-vm" || bad "--help describes mac-vm"
bash "$s" --nonsense >"$tmp/out" 2>&1; [ $? = 2 ] && ok "unknown option exits 2" || bad "unknown option exits 2"

if [ "${WORKAI_CLEAN_MACHINE:-0}" != 1 ]; then
  echo "skip clean-machine run (slow; set WORKAI_CLEAN_MACHINE=1 to run it)"
else
  read -r -a targets <<<"${WORKAI_CLEAN_MACHINE_TARGETS:-}"
  bash "$s" "${targets[@]+"${targets[@]}"}" >"$tmp/out" 2>&1 && ok "every target passes" || bad "every target passes"
  cat "$tmp/out"
  if [ "$(uname -s)" = Darwin ]; then
    bash "$s" --break mac-home >"$tmp/out" 2>&1; rc=$?
    [ "$rc" = 1 ] && grep -q '^  FAIL skills linked' "$tmp/out" && ok "--break makes it fail on skills linked" || bad "--break makes it fail on skills linked"
  fi
fi
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
