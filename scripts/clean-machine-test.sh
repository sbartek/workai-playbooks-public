#!/usr/bin/env bash
# Install on a clean machine, step by step, and say which step failed (card 01-019).
#
#   scripts/clean-machine-test.sh [TARGET...]         default: ubuntu:24.04 ubuntu:26.04 mac-home
#                                                     (mac-vm only when named: it is the slowest)
#   scripts/clean-machine-test.sh --break [TARGET...] sabotage the install; the run must FAIL
#   scripts/clean-machine-test.sh --keep-logs ...     keep the log folder even when everything passes
#
# Targets:
#   ubuntu:NN.NN  a new Docker container of that image (needs Docker and the
#                 network): deps/install-ubuntu.sh --check, --dry-run, run, run
#                 again (must change nothing), --check, install.sh claude
#                 --uninstall, everything gone. As root, the real apt, gh and
#                 Claude Code repos, the pinned release binaries, the real
#                 `claude mcp add`.
#   mac-home      this Mac with a throwaway HOME: install.sh claude (skills,
#                 tools, settings, MCP, CLAUDE.md), deps/install-mac.sh --check,
#                 run again, --uninstall, everything gone. The tools are this
#                 Mac's own (not a clean Mac: that needs a VM, see card 019);
#                 `claude` is a fake that keeps its MCP list in the throwaway
#                 HOME, so the real ~/.claude and ~/.claude.json are never read
#                 or written.
#   mac-vm        a clean macOS VM (tart, Apple Silicon): a throwaway clone of
#                 the local base VM $WORKAI_MAC_VM_BASE (default
#                 workai-clean-mac: cirruslabs vanilla, no Homebrew, user
#                 admin/admin), booted headless, reached by ssh with that
#                 image's default password (SSH_ASKPASS; no key, agent or ssh
#                 config of this Mac goes in). Steps: deps/install-mac.sh
#                 --check fails, without a package manager it says to install
#                 one, Homebrew installs, --dry-run, install, --check, run
#                 again (only ok lines, "tools: nothing missing", no file or
#                 formula changed), install.sh claude --uninstall, all gone.
#                 Refuses below 40 GB free or while another throwaway clone
#                 (workai-cmt-*) exists; stops and deletes the clone on any
#                 exit. The base VM is only cloned, never run or changed.
#
# Every target installs a copy of this checkout (tracked and untracked files,
# not .git), so the branch under test is what runs. --break edits that copy so
# that install.sh says "linked" for each skill but links nothing (a silent
# failure); a run with --break that passes means the checks are blind.
# Prints PASS/FAIL per step and per target; exit 0 only when every step of
# every target ran and passed. Slow (minutes per Ubuntu target), so the normal
# test suite skips it: tests/test-clean-machine.sh runs it only with
# WORKAI_CLEAN_MACHINE=1.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"

# ------------------------------------------------------------ inner steps
# What a second run must leave alone: links, settings, manifest, packages, apt sources.
snapshot() {
  local d
  for d in "$HOME/.claude/skills" "$HOME/.local/bin"; do
    [ -d "$d" ] && for f in "$d"/*; do [ -L "$f" ] && echo "$f -> $(readlink "$f")" || echo "$f"; done
  done
  ls -la "$HOME/.claude" 2>/dev/null | awk '{ print $1, $NF }' | grep -v '\.json$\|^total'
  cat "$HOME/.claude/settings.json" "$HOME/.claude/workai-installed.json" 2>/dev/null
  [ -L "$HOME/.claude/CLAUDE.md" ] && echo "CLAUDE.md -> $(readlink "$HOME/.claude/CLAUDE.md")"
  [ -f "$HOME/.claude/CLAUDE.md" ] && cksum <"$HOME/.claude/CLAUDE.md"
  command -v dpkg-query >/dev/null && dpkg-query -W -f '${Package} ${Version}\n'
  [ "${CMT_KIND:-}" = mac-vm ] && brew list --versions
  ls /etc/apt/sources.list.d /etc/apt/keyrings 2>/dev/null
  [ -d "$HOME/fake-mcp" ] && ls "$HOME/fake-mcp"
  true
}

# Run by the outer script inside the clean environment: one line
# "STEP PASS|FAIL <name>" per step, details indented below a failure.
inner() { # ubuntu|mac-home|mac-vm
  local kind="$1" repo out fails=0
  repo="$(cd "$(dirname "$0")/.." && pwd)"
  out="$(mktemp)"
  step() { # name, then the command; PASS when it exits 0
    local name="$1"; shift
    if "$@" >"$out" 2>&1; then echo "STEP PASS $name"
    else echo "STEP FAIL $name"; sed 's/^/       /' "$out" | tail -40; fails=$((fails + 1)); fi
  }
  # A run that changes nothing prints no line that reports a change.
  # $want_line: a line the output must also hold (one run checks both).
  quiet_run() { # command...
    local log rc
    log="$("$@" 2>&1)"; rc=$?
    echo "$log"
    [ "$rc" = 0 ] || { echo "(exit $rc)"; return 1; }
    [ -z "${want_line:-}" ] || echo "$log" | grep -qxF "$want_line" || { echo "(no line: $want_line)"; return 1; }
    ! echo "$log" | grep -E '^(\+ |linked|relinked|set |added|backup|replaced|removed|created|migrated|tools: installing)'
  }
  skills_linked() {
    local n; n="$(ls "$HOME/.claude/skills" 2>/dev/null | grep -c '^workai-')"
    echo "$n workai-* skill links"; ls -l "$HOME/.claude/skills" 2>/dev/null
    [ "$n" -gt 0 ] && [ -f "$HOME/.claude/skills/workai-backlog/SKILL.md" ]
  }
  setup_present() {
    local s="$HOME/.claude/settings.json"
    [ "$(jq -r .tui "$s")" = fullscreen ] && [ "$(jq -r .skipWorkflowUsageWarning "$s")" = true ] || { echo "settings: tui/skipWorkflowUsageWarning not set"; cat "$s"; return 1; }
    if [ "$kind" != ubuntu ]; then
      jq -e '.autoMode.soft_deny | index("Bash(tmutil delete:*)")' "$s" >/dev/null || { echo "Mac soft_deny tmutil missing"; return 1; }
    fi
    claude mcp get youtrack || { echo "MCP youtrack not registered"; return 1; }
    [ -f "$HOME/.claude/CLAUDE.md" ] && [ ! -L "$HOME/.claude/CLAUDE.md" ] || { echo "CLAUDE.md is not a plain file"; return 1; }
    [ -L "$HOME/.local/bin/workai-secret" ] || { echo "workai-secret not linked"; return 1; }
    [ -f "$HOME/.claude/workai-installed.json" ] || { echo "no manifest"; return 1; }
  }
  all_gone() {
    local left
    left="$(ls "$HOME/.claude/skills" "$HOME/.local/bin" 2>/dev/null | grep '^workai-')"
    [ -z "$left" ] || { echo "left behind: $left"; return 1; }
    [ ! -e "$HOME/.claude/CLAUDE.md" ] && [ ! -L "$HOME/.claude/CLAUDE.md" ] || { echo "CLAUDE.md still there"; return 1; }
    [ ! -e "$HOME/.claude/workai-installed.json" ] || { echo "manifest still there"; cat "$HOME/.claude/workai-installed.json"; return 1; }
    [ ! -f "$HOME/.claude/settings.json" ] || [ "$(jq -r '.tui // "none"' "$HOME/.claude/settings.json")" = none ] || { echo "settings tui still set"; return 1; }
    [ ! -f "$HOME/.claude/settings.json" ] || [ "$(jq -r '.skipWorkflowUsageWarning // "none"' "$HOME/.claude/settings.json")" = none ] || { echo "settings skipWorkflowUsageWarning still set"; return 1; }
    ! claude mcp get youtrack || { echo "MCP youtrack still registered"; return 1; }
  }
  check_says_nothing_missing() { "$@" && "$@" | grep -qx 'nothing missing'; }
  fails_now() { ! "$@"; }

  case "$kind" in
    ubuntu)
      local deps="$repo/deps/install-ubuntu.sh" before
      local bare="$PATH" full="$HOME/.local/bin:$PATH"
      step "fresh machine: --check reports missing tools and skills" fails_now "$deps" --check
      before="$(snapshot)"
      step "--dry-run prints commands and changes nothing" bash -c '"$1" --dry-run | grep -q "^+ " && [ "$(snapshot)" = "$2" ]' _ "$deps" "$before"
      # First run as a new user would: ~/.local/bin (workmux, gitleaks) not yet on PATH.
      step "first run without ~/.local/bin on PATH says to add it" bash -c 'PATH="$2"; out="$("$1" 2>&1)"; echo "$out"; echo "$out" | grep -q "is not on PATH"' _ "$deps" "$bare"
      export PATH="$full"; hash -r
      step "install (~/.local/bin on PATH) exits 0" "$deps"
      step "skills linked" skills_linked
      step "settings, MCP, CLAUDE.md and tools in place" setup_present
      step "--check: nothing missing" check_says_nothing_missing "$deps" --check
      before="$(snapshot)"
      step "second run prints only ok lines" quiet_run "$deps"
      step "second run changed no file or package" bash -c '[ "$(snapshot)" = "$1" ] || { diff <(echo "$1") <(snapshot); exit 1; }' _ "$before"
      step "install.sh claude --uninstall exits 0" "$repo/install.sh" claude --uninstall
      step "skills, tools, settings, MCP, CLAUDE.md and manifest gone" all_gone
      ;;
    mac-home)
      local before
      step "fresh HOME: install.sh claude --check reports missing" fails_now "$repo/install.sh" claude --check
      step "install.sh claude exits 0" "$repo/install.sh" claude
      step "skills linked" skills_linked
      step "settings (with Mac soft_deny), MCP, CLAUDE.md and tools in place" setup_present
      step "deps/install-mac.sh --check: nothing missing" check_says_nothing_missing "$repo/deps/install-mac.sh" --check
      before="$(snapshot)"
      step "second run prints only ok lines" quiet_run "$repo/install.sh" claude
      step "second run changed no file" bash -c '[ "$(snapshot)" = "$1" ] || { diff <(echo "$1") <(snapshot); exit 1; }' _ "$before"
      step "install.sh claude --uninstall exits 0" "$repo/install.sh" claude --uninstall
      step "skills, tools, settings, MCP, CLAUDE.md and manifest gone" all_gone
      ;;
    mac-vm)
      local deps="$repo/deps/install-mac.sh" before
      export CMT_KIND=mac-vm PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      no_package_manager() { local o rc; o="$("$deps" 2>&1)"; rc=$?; echo "$o"; [ "$rc" = 1 ] && echo "$o" | grep -q '^no package manager'; }
      second_run_ok() { want_line='tools: nothing missing' quiet_run "$deps"; }
      step "fresh Mac: --check reports missing tools and skills" fails_now "$deps" --check
      step "no Homebrew/MacPorts: says to install one, exits 1" no_package_manager
      # What a person does from brew.sh; the installer also brings the Command Line Tools.
      step "Homebrew installs (brew.sh, NONINTERACTIVE)" bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && [ -x /opt/homebrew/bin/brew ]'
      [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"; hash -r
      before="$(snapshot)"
      step "--dry-run prints brew bundle and changes nothing" bash -c 'out="$("$1" --dry-run)"; echo "$out"; echo "$out" | grep -q "^+ brew bundle" && [ "$(snapshot)" = "$2" ]' _ "$deps" "$before"
      step "install exits 0" "$deps"
      step "skills linked" skills_linked
      step "settings (with Mac soft_deny), MCP, CLAUDE.md and tools in place" setup_present
      step "--check: nothing missing" check_says_nothing_missing "$deps" --check
      before="$(snapshot)"
      step "second run prints only ok lines and tools: nothing missing" second_run_ok
      step "second run changed no file or formula" bash -c '[ "$(snapshot)" = "$1" ] || { diff <(echo "$1") <(snapshot); exit 1; }' _ "$before"
      step "install.sh claude --uninstall exits 0" "$repo/install.sh" claude --uninstall
      step "skills, tools, settings, MCP, CLAUDE.md and manifest gone" all_gone
      ;;
  esac
  rm -f "$out"
  echo "STEPS DONE fails=$fails"
  [ "$fails" = 0 ]
}

if [ "${1:-}" = --inner ]; then
  kind="$2"
  export -f snapshot   # used inside `bash -c` steps
  inner "$kind"; exit $?
fi

# ------------------------------------------------------------ outer driver
usage() { sed -n '4,6p' "$0" | sed 's/^# *//'; exit 2; }
brk=0; keep=0; targets=()
for a in "$@"; do
  case "$a" in
    --break) brk=1 ;;
    --keep-logs) keep=1 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    ubuntu:*|mac-home|mac-vm) targets+=("$a") ;;
    *) usage ;;
  esac
done
[ ${#targets[@]} -gt 0 ] || targets=(ubuntu:24.04 ubuntu:26.04 mac-home)
expected_steps() { case "$1" in ubuntu:*) echo 11 ;; mac-home) echo 9 ;; mac-vm) echo 12 ;; esac; }

work="$(mktemp -d)"; work="$(cd "$work" && pwd -P)"
logs="$work/logs"; mkdir -p "$logs"
vm=""   # the throwaway tart clone, while it exists
drop_vm() { # stop and delete the throwaway clone (never anything else)
  [ -n "$vm" ] || return 0
  case "$vm" in workai-cmt-*) ;; *) vm=""; return 0 ;; esac
  "$tart" stop "$vm" >/dev/null 2>&1
  if "$tart" delete "$vm"; then echo "deleted VM $vm"; vm=""
  else echo "STEP FAIL could not delete VM $vm: run tart delete $vm (later runs refuse while it exists)"; return 1; fi
}
cleanup() {
  drop_vm
  if [ "$keep" = 1 ] || [ "${failed:-1}" != 0 ]; then
    rm -rf "$work/copy" "$work/home"; echo "logs: $logs"
  else rm -rf "$work"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The checkout under test, without .git.
copy="$work/copy"; mkdir -p "$copy"
git -C "$here" ls-files -z -co --exclude-standard | (cd "$here" && xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$copy" \
  || { echo "could not copy $here"; exit 2; }
[ -x "$copy/install.sh" ] && [ -f "$copy/scripts/clean-machine-test.sh" ] || { echo "copy of $here is incomplete"; exit 2; }
if [ "$brk" = 1 ]; then
  # Break the skills step silently: report "linked" without linking.
  perl -0pi -e 's/else ln -s "\$want" "\$link" && note "linked   \$name"; fi/else note "linked   \$name"; fi/' "$copy/install.sh"
  grep -q 'else note "linked   \$name"; fi' "$copy/install.sh" || { echo "--break did not apply to install.sh; fix the pattern"; exit 2; }
  echo "BROKEN on purpose: install.sh reports skills as linked without linking them"
fi

# mac-vm: clone the base VM, boot it headless, copy the checkout in over ssh,
# run the steps there; the EXIT trap stops and deletes the clone.
tart="$(command -v tart || echo "$HOME/.local/bin/tart")"
run_mac_vm() {
  local base="${WORKAI_MAC_VM_BASE:-workai-clean-mac}" free others ip i
  local user="${WORKAI_MAC_VM_USER:-admin}"
  [ "$(uname -s) $(uname -m)" = "Darwin arm64" ] || { echo "mac-vm needs an Apple Silicon Mac"; return 1; }
  [ -x "$tart" ] || { echo "tart not found (see card 01-019)"; return 1; }
  "$tart" list --source local --quiet | grep -qx "$base" || { echo "base VM $base not found (tart list)"; return 1; }
  free="$(df -g "$HOME/.tart" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [ "${free:-0}" -ge 40 ] || { echo "refusing: ${free:-?} GB free, mac-vm needs 40 GB"; return 1; }
  others="$("$tart" list --source local --quiet | grep '^workai-cmt-')"
  [ -z "$others" ] || { echo "refusing: a throwaway clone already exists (another run, or a killed one): $others; delete it with: tart delete <name>"; return 1; }
  vm="workai-cmt-$$"
  [ "$vm" != "$base" ] || return 1
  "$tart" clone "$base" "$vm" || { vm=""; echo "tart clone failed"; return 1; }
  echo "VM $vm cloned from $base ($free GB free before)"
  "$tart" run --no-graphics "$vm" >"$work/tart-run.log" 2>&1 &
  ip="$("$tart" ip --wait 180 "$vm")" || { echo "VM got no IP"; cat "$work/tart-run.log"; return 1; }
  # The vanilla image's default password, given by SSH_ASKPASS. -F /dev/null
  # and no pubkey/agent: nothing of this Mac's ssh setup reaches the VM.
  printf '#!/bin/sh\necho "%s"\n' "${WORKAI_MAC_VM_PASSWORD:-admin}" >"$work/askpass"; chmod 700 "$work/askpass"
  vssh() {
    SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh -F /dev/null \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o PubkeyAuthentication=no -o IdentityAgent=none -o ForwardAgent=no \
      -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout=10 -o ServerAliveInterval=30 "$user@$ip" "$@" </dev/null
  }
  for i in $(seq 1 36); do vssh true 2>/dev/null && break; sleep 5; done
  vssh true || { echo "no ssh to $user@$ip"; return 1; }
  echo "VM $vm up at $ip ($(vssh 'sw_vers -productVersion; uname -m' | tr '\n' ' '))"
  tar -C "$copy" -cf - . | SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh -F /dev/null \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o PubkeyAuthentication=no -o IdentityAgent=none -o PreferredAuthentications=password,keyboard-interactive \
      "$user@$ip" 'mkdir -p workai-playbooks && tar -xf - -C workai-playbooks' || { echo "copy into the VM failed"; return 1; }
  vssh 'bash workai-playbooks/scripts/clean-machine-test.sh --inner mac-vm' >"$log" 2>&1
}

failed=0; summary=()
for t in "${targets[@]}"; do
  log="$logs/${t//[:\/]/-}.log"
  echo "== $t"
  case "$t" in
    ubuntu:*)
      command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "Docker is not running"; echo "STEP FAIL docker available" >"$log"; }
      [ -s "$log" ] || docker run --rm -e HOME=/root -v "$copy:/opt/workai-playbooks:ro" "$t" \
        bash /opt/workai-playbooks/scripts/clean-machine-test.sh --inner ubuntu >"$log" 2>&1
      rc=$? ;;
    mac-home)
      [ "$(uname -s)" = Darwin ] || { echo "mac-home runs only on a Mac"; exit 2; }
      h="$work/home"; mkdir -p "$h"
      fake="$work/fakebin"; mkdir -p "$fake"
      cat >"$fake/claude" <<'EOF'
#!/bin/bash
# Fake `claude mcp get|add|remove`; state in $HOME/fake-mcp (a throwaway HOME).
[ "$1" = mcp ] || exit 2
d="$HOME/fake-mcp"; mkdir -p "$d"
case "$2" in
  get) [ -f "$d/$3" ] || { echo "No MCP server named \"$3\""; exit 1; }
       printf '%s:\n  Scope: User config\n  Command: %s\n' "$3" "$(cat "$d/$3")" ;;
  add) [ "$3 $4" = "--scope user" ] && [ "$6" = -- ] || exit 3
       [ -f "$d/$5" ] && exit 1; echo "$7" >"$d/$5" ;;
  remove) [ "$3" = --scope ] && shift 2; [ -f "$d/$3" ] && rm "$d/$3" ;;
  *) exit 2 ;;
esac
EOF
      chmod +x "$fake/claude"
      # Only HOME and PATH come from here: no CLAUDE_*/WORKAI_* overrides leak in.
      [ "$(cd "$h" && pwd -P)" != "$(cd ~ && pwd -P)" ] || { echo "refusing: throwaway HOME is the real one"; exit 2; }
      env -i HOME="$h" PATH="$fake:$PATH" TERM=dumb LANG="${LANG:-en_US.UTF-8}" \
        bash "$copy/scripts/clean-machine-test.sh" --inner mac-home >"$log" 2>&1
      rc=$? ;;
    mac-vm)
      run_mac_vm >"$log.driver" 2>&1; rc=$?
      drop_vm >>"$log.driver" 2>&1 || { rc=1; tail -1 "$log.driver" >>"$log"; }
      cat "$log.driver"; [ -f "$log" ] || cp "$log.driver" "$log" ;;
  esac
  grep '^STEP ' "$log" | sed 's/^STEP /  /'
  ran="$(grep -c '^STEP PASS\|^STEP FAIL' "$log")"
  bad="$(grep -c '^STEP FAIL' "$log")"
  want="$(expected_steps "$t")"
  if [ "$rc" = 0 ] && [ "$bad" = 0 ] && [ "$ran" = "$want" ] && grep -q '^STEPS DONE fails=0' "$log"; then
    summary+=("PASS $t ($ran/$want steps)")
  else
    [ "$ran" = "$want" ] || echo "  only $ran of $want steps ran (exit $rc); last lines of $log:" && [ "$ran" = "$want" ] || tail -15 "$log" | sed 's/^/    /'
    summary+=("FAIL $t ($bad failed, $ran/$want steps ran, exit $rc)"); failed=1
  fi
done
echo "== summary"
printf '%s\n' "${summary[@]}"
[ "$brk" = 1 ] && echo "(--break: these targets were meant to FAIL)"
exit "$failed"
