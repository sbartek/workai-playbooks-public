#!/usr/bin/env bash
# Install what the playbook needs on Ubuntu (24.04 LTS or newer; x86_64 or
# arm64), then the skills. Same tool list as the Mac: deps/tools.txt.
#
#   deps/install-ubuntu.sh             install what is missing, then install.sh claude
#   deps/install-ubuntu.sh --check     list what is missing (tools and skills), change nothing
#   deps/install-ubuntu.sh --dry-run   print the commands it would run
#   ... --release                      skills from the newest release (install.sh claude --release)
#
# Only missing tools are installed, so a second run changes nothing.
# Ubuntu packages with apt-get; gh from GitHub's apt repository and Claude
# Code from Anthropic's (stable channel, signing key fingerprint checked), as
# their docs say; workmux and gitleaks as release binaries whose SHA-256 is
# pinned in deps/release-binaries.txt (into ~/.local/bin). Uses sudo unless
# run as root (e.g. in a container).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mode=install; skills_args=()
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --dry-run) dry=1 ;;
    --release) skills_args+=(--release) ;;
    *) sed -n '5,8p' "$0" | sed 's/^# *//'; exit 2 ;;
  esac
done

[ "${WORKAI_OS:-$(uname -s)}" = Linux ] || { echo "not Linux; use deps/install-mac.sh on a Mac"; exit 2; }
etc="${WORKAI_APT_ROOT:-}/etc"   # override: tests
if [ -r "$etc/os-release" ]; then
  . "$etc/os-release"
  [ "${ID:-}" = ubuntu ] || echo "warning: this is ${PRETTY_NAME:-not Ubuntu}; written for Ubuntu"
fi
[ "$mode" = check ] && { check_all "${skills_args[@]+"${skills_args[@]}"}"; exit $?; }

if [ "$(id -u)" = 0 ]; then as_root() { run "$@"; }; else as_root() { run sudo "$@"; }; fi
apt_install() { as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"; }

ANTHROPIC_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE   # https://code.claude.com/docs/en/setup

# Add a vendor apt repository once: keyring + sources list.
add_repo() { # gh | claude-code
  local key list url line
  case "$1" in
    gh) key="$etc/apt/keyrings/githubcli-archive-keyring.gpg"; list="$etc/apt/sources.list.d/github-cli.list"
        url=https://cli.github.com/packages/githubcli-archive-keyring.gpg
        line="deb [arch=$(dpkg --print-architecture) signed-by=$key] https://cli.github.com/packages stable main" ;;
    claude-code) key="$etc/apt/keyrings/claude-code.asc"; list="$etc/apt/sources.list.d/claude-code.list"
        url=https://downloads.claude.ai/keys/claude-code.asc
        line="deb [signed-by=$key] https://downloads.claude.ai/claude-code/apt/stable stable main" ;;
    *) echo "unknown repo $1"; return 1 ;;
  esac
  [ -f "$list" ] && [ -f "$key" ] && return 0
  as_root install -d -m 0755 "$etc/apt/keyrings" "$etc/apt/sources.list.d" || return 1
  as_root curl -fsSL -o "$key" "$url" || return 1
  as_root chmod go+r "$key" || return 1
  if [ "$1" = claude-code ] && [ "$dry" = 0 ]; then
    gpg --show-keys --with-colons "$key" 2>/dev/null | grep -q "^fpr:::::::::$ANTHROPIC_FPR:" \
      || { echo "Claude Code signing key fingerprint is not $ANTHROPIC_FPR; stopping"; as_root rm -f "$key"; return 1; }
  fi
  echo "+ write $list"
  [ "$dry" = 1 ] || echo "$line" | as_root tee "$list" >/dev/null
}

missing="$(missing_tools)"
if [ -z "$missing" ]; then
  echo "tools: nothing missing"
else
  echo "tools: installing: $(echo $missing)"
  pkgs=(); repos=(); releases=()
  for name in $missing; do
    a="$(tools_col 4 | awk -v n="$name" '$1 == n { print $2 }')"
    case "$a" in
      release) releases+=("$name") ;;
      repo:*) repos+=("${a#repo:}") ;;
      -|"") echo "no Ubuntu route for $name"; exit 1 ;;
      *) pkgs+=("$a") ;;
    esac
  done
  # What the vendor repos and downloads need.
  pre=()
  command -v curl >/dev/null 2>&1 || pre+=(curl ca-certificates)
  [ ${#repos[@]} -gt 0 ] && ! command -v gpg >/dev/null 2>&1 && pre+=(gnupg)
  if [ ${#pre[@]} -gt 0 ] || [ ${#pkgs[@]} -gt 0 ]; then
    as_root apt-get update -q || exit 1
    apt_install "${pre[@]+"${pre[@]}"}" "${pkgs[@]+"${pkgs[@]}"}" || exit 1
  fi
  if [ ${#repos[@]} -gt 0 ]; then
    for r in "${repos[@]}"; do add_repo "$r" || exit 1; done
    as_root apt-get update -q || exit 1
    apt_install "${repos[@]}" || exit 1
  fi
  for t in "${releases[@]+"${releases[@]}"}"; do install_release "$t" || exit 1; done
fi
path_warning

[ "$dry" = 1 ] && { echo "+ $repo/install.sh claude ${skills_args[*]+"${skills_args[*]}"}"; exit 0; }
hash -r
still="$(missing_tools)"
if [ -n "$still" ]; then
  echo "still missing after install: $(echo $still)"
  case " $still " in *" python3 "*) echo "python3 must be 3.11 or newer: use Ubuntu 24.04 LTS or later" ;; esac
  echo "(open a new shell if PATH changed)"
  exit 1
fi
"$repo/install.sh" claude "${skills_args[@]+"${skills_args[@]}"}"
