# shellcheck shell=bash
# Shared by install-mac.sh and install-ubuntu.sh (sourced, not run).
# Reads tools.txt and release-binaries.txt next to this file.

deps="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$deps/.." && pwd)"
bin_dir="${WORKAI_BIN_DIR:-$HOME/.local/bin}"
releases_file="${WORKAI_RELEASE_BINARIES:-$deps/release-binaries.txt}"   # override: tests
dry=0

# Print "name value" for each tool, value from column N (2 brew, 3 port, 4 apt).
tools_col() {
  awk -v c="$1" '!/^#/ && NF >= 4 { print $1, $c }' "$deps/tools.txt"
}

# Is the tool usable? python3 must also be 3.11 or newer.
have() {
  command -v "$1" >/dev/null 2>&1 || return 1
  if [ "$1" = python3 ]; then
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null || return 1
  fi
  return 0
}

missing_tools() {
  local name _
  while read -r name _; do have "$name" || echo "$name"; done < <(tools_col 2)
}

# Run a command, or only print it with --dry-run.
run() {
  echo "+ $*"
  [ "$dry" = 1 ] && return 0
  "$@"
}

machine() { # os arch, as release-binaries.txt spells them
  local os arch
  case "${WORKAI_OS:-$(uname -s)}" in Darwin) os=darwin ;; Linux) os=linux ;; *) os=unknown ;; esac
  case "${WORKAI_ARCH:-$(uname -m)}" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x86_64 ;; *) arch=unknown ;; esac
  echo "$os $arch"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Download a pinned release binary, check its SHA-256, put it in $bin_dir.
install_release() { # tool
  local tool="$1" os arch url sum tmp
  read -r os arch < <(machine)
  read -r url sum < <(awk -v t="$tool" -v o="$os" -v a="$arch" \
    '!/^#/ && $1 == t && $2 == o && $3 == a { print $4, $5 }' "$releases_file")
  [ -n "${url:-}" ] || { echo "no pinned release of $tool for $os/$arch in release-binaries.txt"; return 1; }
  echo "+ download $url -> $bin_dir/$tool (sha256 pinned)"
  [ "$dry" = 1 ] && return 0
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/pkg.tar.gz" "$url" || { rm -rf "$tmp"; echo "download failed: $url"; return 1; }
  [ "$(sha256 "$tmp/pkg.tar.gz")" = "$sum" ] || { rm -rf "$tmp"; echo "SHA-256 mismatch for $url; not installed"; return 1; }
  mkdir -p "$tmp/x" "$bin_dir"
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp/x" "$tool" || { rm -rf "$tmp"; echo "$tool not in $url"; return 1; }
  install -m 0755 "$tmp/x/$tool" "$bin_dir/$tool"
  rm -rf "$tmp"
}

path_warning() {
  case ":$PATH:" in *":$bin_dir:"*) ;; *)
    echo "note: $bin_dir is not on PATH; add it in your shell profile (export PATH=\"$bin_dir:\$PATH\")" ;;
  esac
}

# --check: list what is missing, then the Claude setup (skills, settings, MCP). Exit 1 on anything missing.
check_all() {
  local name problems=0
  while read -r name _; do
    if have "$name"; then echo "ok       $name ($(command -v "$name"))"
    else echo "missing  $name"; problems=$((problems + 1)); fi
  done < <(tools_col 2)
  "$repo/install.sh" claude --check "$@" >/dev/null 2>&1 \
    && echo "ok       claude setup: skills, settings, MCP (install.sh claude --check)" \
    || { echo "missing  claude setup: skills, settings or MCP (run: $repo/install.sh claude $*)"; problems=$((problems + 1)); }
  [ "$problems" = 0 ] && { echo "nothing missing"; return 0; }
  echo "$problems missing"; return 1
}
