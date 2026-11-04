#!/usr/bin/env bash
# Install what the playbook needs on a Mac (Apple Silicon or Intel), then the
# skills. Uses the package manager it finds: Homebrew, else MacPorts.
#
#   deps/install-mac.sh             install what is missing, then install.sh claude
#   deps/install-mac.sh --check     list what is missing (tools and skills), change nothing
#   deps/install-mac.sh --dry-run   print the commands it would run
#   deps/install-mac.sh --brewfile  print the Brewfile for the tools in tools.txt
#   ... --release                   skills from the newest release (install.sh claude --release)
#
# Only missing tools are installed, so a second run changes nothing and a tool
# already installed another way (e.g. claude from its own installer) is left
# alone. Homebrew: `brew bundle --no-upgrade` on a Brewfile of the missing
# tools. MacPorts: `sudo port install`, python3 via `port select`, workmux
# (no port) as a pinned release binary in ~/.local/bin, Claude Code with
# Anthropic's native installer (~/.local/bin/claude).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mode=install; skills_args=()
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --dry-run) dry=1 ;;
    --brewfile) mode=brewfile ;;
    --release) skills_args+=(--release) ;;
    *) sed -n '5,9p' "$0" | sed 's/^# *//'; exit 2 ;;
  esac
done

brewfile() { # tool names on stdin -> Brewfile lines
  local name entry
  while read -r name; do
    entry="$(tools_col 2 | awk -v n="$name" '$1 == n { print $2 }')"
    case "$entry" in
      -|"") ;;
      cask:*) echo "cask \"${entry#cask:}\"" ;;
      */*/*) echo "tap \"${entry%/*}\""; echo "brew \"$entry\"" ;;
      *) echo "brew \"$entry\"" ;;
    esac
  done
}

[ "${WORKAI_OS:-$(uname -s)}" = Darwin ] || { echo "not macOS; use deps/install-ubuntu.sh on Ubuntu"; exit 2; }
case "$mode" in
  brewfile) tools_col 2 | cut -d' ' -f1 | brewfile; exit 0 ;;
  check) check_all "${skills_args[@]+"${skills_args[@]}"}"; exit $? ;;
esac

missing="$(missing_tools)"
if [ -z "$missing" ]; then
  echo "tools: nothing missing"
elif command -v brew >/dev/null 2>&1; then
  echo "tools: installing with Homebrew: $(echo $missing)"
  bf="$(mktemp)"; echo "$missing" | brewfile >"$bf"
  # Homebrew 7 refuses formulae from taps nobody trusted; trust only the tap
  # formulae tools.txt names (not the whole tap), and only if brew knows `trust`.
  for f in $(awk -F'"' '$1 == "brew " && $2 ~ /\/.*\// { print $2 }' "$bf"); do
    brew trust --help >/dev/null 2>&1 || break
    run brew trust --formula "$f" || { rm -f "$bf"; echo "brew trust failed"; exit 1; }
  done
  run brew bundle install --no-upgrade --file="$bf" || { rm -f "$bf"; echo "brew bundle failed"; exit 1; }
  rm -f "$bf"
elif command -v port >/dev/null 2>&1; then
  echo "tools: installing with MacPorts: $(echo $missing)"
  ports=()
  for name in $missing; do
    p="$(tools_col 3 | awk -v n="$name" '$1 == n { print $2 }')"
    case "$p" in
      release) install_release "$name" || exit 1 ;;
      native) [ "$name" = claude ] && { echo "+ curl -fsSL https://claude.ai/install.sh | bash"
                [ "$dry" = 1 ] || curl -fsSL https://claude.ai/install.sh | bash || exit 1; } ;;
      -|"") echo "no MacPorts route for $name"; exit 1 ;;
      *) ports+=("$p") ;;
    esac
  done
  if [ ${#ports[@]} -gt 0 ]; then
    run sudo port install "${ports[@]}" || exit 1
    for p in "${ports[@]}"; do
      case "$p" in python3*) have python3 || run sudo port select --set python3 "$p" || exit 1 ;; esac
    done
  fi
else
  echo "no package manager: install Homebrew (https://brew.sh) or MacPorts (https://www.macports.org), then run this again"
  exit 1
fi
path_warning

[ "$dry" = 1 ] && { echo "+ $repo/install.sh claude ${skills_args[*]+"${skills_args[*]}"}"; exit 0; }
hash -r
still="$(missing_tools)"
[ -z "$still" ] || { echo "still missing after install: $(echo $still) (open a new shell if PATH changed)"; exit 1; }
"$repo/install.sh" claude "${skills_args[@]+"${skills_args[@]}"}"
