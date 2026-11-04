#!/usr/bin/env bash
# Tests for deps/install-mac.sh (and deps/install-ubuntu.sh when present)
# with fake package managers on a PATH that holds no real tool from
# tools.txt. Nothing is installed on this machine; HOME and the skills
# folder are throwaway.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
tools="$(awk '!/^#/ && NF >= 4 { print $1 }' "$here/deps/tools.txt")"

# System utilities only (no git, python3, jq, tmux, ... from the real machine).
sys="$tmp/sys"; mkdir -p "$sys"
for u in bash sh env cat sed awk grep mkdir rm mv cp ln chmod mktemp dirname basename tr cut head tail sort \
         uname readlink ls wc tar gzip shasum sha256sum install printf date touch perl tee id; do
  p="$(command -v "$u" 2>/dev/null)" && ln -sf "$p" "$sys/$u"
done

stub_tool() { # dir name [python-version]
  if [ "$2" = python3 ]; then
    printf '#!/bin/sh\nexit %s\n' "${3:-0}" >"$1/python3"   # exit 0 = new enough
  else printf '#!/bin/sh\necho "%s stub"\n' "$2" >"$1/$2"; fi
  chmod +x "$1/$2"
}

# Fake brew: `brew bundle install --no-upgrade --file=F` installs a stub for each line.
fake_brew() { # bindir log
  cat >"$1/brew" <<EOF
#!/bin/bash
[ "\$1" = trust ] && { [ "\$2" = --help ] || echo "brew \$*" >>"$2.trust"; exit 0; }
echo "brew \$*" >>"$2"
[ -f "$2.trust" ] && echo "bundle after trust" >>"$2.order" || echo "bundle before trust" >>"$2.order"
f=""; for a in "\$@"; do case "\$a" in --file=*) f="\${a#--file=}" ;; esac; done
cp "\$f" "$2.brewfile.\$(wc -l <"$2" | tr -d ' ')"
while read -r kind name; do
  name="\${name//\\"/}"
  case "\$kind:\$name" in
    tap:*) ;;
    cask:claude-code) cmd=claude ;; brew:python) cmd=python3 ;; brew:*/*) cmd="\${name##*/}" ;; *) cmd="\$name" ;;
  esac
  [ "\$kind" = tap ] && continue
  if [ "\$cmd" = python3 ]; then printf '#!/bin/sh\nexit 0\n' >"$1/python3"; else printf '#!/bin/sh\necho stub\n' >"$1/\$cmd"; fi
  chmod +x "$1/\$cmd"
done <"\$f"
EOF
  chmod +x "$1/brew"
}

export HOME="$tmp/home" CLAUDE_SKILLS_DIR="$tmp/home/.claude/skills"; mkdir -p "$HOME"
# jq and claude are stubs here, so only the skills part of install.sh runs.
export WORKAI_INSTALL_PARTS=skills CLAUDE_CONFIG_HOME="$tmp/home/.claude" CLAUDE_BIN="$tmp/no-claude"

# --- Homebrew route ---------------------------------------------------------
bin="$tmp/brewbin"; mkdir -p "$bin"; log="$tmp/brew.log"; fake_brew "$bin" "$log"
P="$bin:$sys"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" --check >"$tmp/out" 2>&1; rc=$?
n="$(grep -c '^missing ' "$tmp/out")"
[ "$rc" = 1 ] && [ "$n" = "$(( $(echo "$tools" | wc -l) + 1 ))" ] && ok "--check lists every tool and the skills as missing" || bad "--check lists every tool and the skills as missing"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" --dry-run >"$tmp/out" 2>&1
[ ! -e "$log" ] && grep -q '^+ brew bundle install --no-upgrade' "$tmp/out" && ok "--dry-run prints, runs nothing" || bad "--dry-run prints, runs nothing"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1 && ok "install exits 0" || bad "install exits 0"
[ "$(wc -l <"$log" | tr -d ' ')" = 1 ] && ok "brew bundle ran once" || bad "brew bundle ran once"
bf="$log.brewfile.1"
for want in 'tap "raine/workmux"' 'brew "raine/workmux/workmux"' 'cask "claude-code"' 'brew "gh"' 'brew "gitleaks"' 'brew "python"'; do
  grep -qxF "$want" "$bf" 2>/dev/null && ok "Brewfile has $want" || bad "Brewfile has $want"
done
[ "$(cat "$log.trust" 2>/dev/null)" = "brew trust --formula raine/workmux/workmux" ] && [ "$(head -1 "$log.order")" = "bundle after trust" ] && ok "trusts only the tap formula, before bundle" || bad "trusts only the tap formula, before bundle"
[ -L "$CLAUDE_SKILLS_DIR/workai-backlog" ] && ok "skills installed" || bad "skills installed"
before="$(ls -l "$bin" "$CLAUDE_SKILLS_DIR")"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1
[ "$(wc -l <"$log" | tr -d ' ')" = 1 ] && grep -q 'tools: nothing missing' "$tmp/out" && [ "$(ls -l "$bin" "$CLAUDE_SKILLS_DIR")" = "$before" ] \
  && ok "second run changes nothing" || bad "second run changes nothing"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" --check >"$tmp/out" 2>&1 && grep -q 'nothing missing' "$tmp/out" && ok "--check reports nothing missing afterwards" || bad "--check reports nothing missing afterwards"
stub_tool "$bin" python3 1
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" --check >"$tmp/out" 2>&1; grep -q '^missing  python3' "$tmp/out" && ok "python3 older than 3.11 counts as missing" || bad "python3 older than 3.11 counts as missing"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1
grep -qx 'brew "python"' "$log.brewfile.2" 2>/dev/null && [ "$(grep -c . "$log.brewfile.2")" = 1 ] && ok "only the missing tool goes in the Brewfile" || bad "only the missing tool goes in the Brewfile"
PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" --brewfile >"$tmp/out" 2>&1
[ "$(grep -c '^brew \|^cask ' "$tmp/out")" = "$(echo "$tools" | wc -l | tr -d ' ')" ] && ok "--brewfile covers every tool" || bad "--brewfile covers every tool"

# --- MacPorts route ---------------------------------------------------------
rm -rf "$HOME" "$tmp/portbin"; mkdir -p "$HOME"; bin="$tmp/portbin"; mkdir -p "$bin"; plog="$tmp/port.log"
cat >"$bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat >"$bin/port" <<EOF
#!/bin/bash
echo "port \$*" >>"$plog"
[ "\$1" = install ] || exit 0
shift
for p in "\$@"; do
  case "\$p" in python3*) printf '#!/bin/sh\nexit 0\n' >"$bin/python3.13"; chmod +x "$bin/python3.13" ;;
    *) printf '#!/bin/sh\necho stub\n' >"$bin/\$p"; chmod +x "$bin/\$p" ;; esac
done
EOF
# port select makes python3 appear.
cat >>"$bin/port" <<EOF
EOF
sed -i.bak 's|^\[ "\$1" = install \] \|\| exit 0|[ "\$1" = select ] \&\& { printf "#!/bin/sh\\nexit 0\\n" >"'"$bin"'/python3"; chmod +x "'"$bin"'/python3"; exit 0; }\n[ "\$1" = install ] \|\| exit 0|' "$bin/port"
# Fake release tarball for workmux, and a fake native Claude installer.
mkdir -p "$tmp/pkg"; printf '#!/bin/sh\necho workmux stub\n' >"$tmp/pkg/workmux"; chmod +x "$tmp/pkg/workmux"
tar -czf "$tmp/workmux.tar.gz" -C "$tmp/pkg" workmux
sum="$(shasum -a 256 "$tmp/workmux.tar.gz" | cut -d' ' -f1)"
arch="$(uname -m)"; [ "$arch" = aarch64 ] && arch=arm64
printf 'workmux darwin %s https://example.invalid/workmux.tar.gz %s\n' "$arch" "$sum" >"$tmp/releases.txt"
cat >"$bin/curl" <<EOF
#!/bin/bash
echo "curl \$*" >>"$tmp/curl.log"
out=""; url=""; while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; -*) ;; *) url="\$1" ;; esac; shift; done
case "\$url" in
  *workmux.tar.gz) cp "$tmp/workmux.tar.gz" "\$out" ;;
  https://claude.ai/install.sh) printf 'mkdir -p "\$HOME/.local/bin"; printf "#!/bin/sh\\\\necho claude\\\\n" >"\$HOME/.local/bin/claude"; chmod +x "\$HOME/.local/bin/claude"\n' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$bin/sudo" "$bin/port" "$bin/curl"
P="$bin:$HOME/.local/bin:$sys"
WORKAI_RELEASE_BINARIES="$tmp/releases.txt" PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1 && ok "MacPorts route installs" || bad "MacPorts route installs"
grep -q '^port install git tmux jq python313 gh gitleaks$' "$plog" && ok "one port install with the port names" || bad "one port install with the port names"
grep -q '^port select --set python3 python313$' "$plog" && ok "python3 selected" || bad "python3 selected"
[ -x "$HOME/.local/bin/workmux" ] && ok "workmux from the pinned release" || bad "workmux from the pinned release"
[ -x "$HOME/.local/bin/claude" ] && ok "claude from the native installer" || bad "claude from the native installer"
n="$(wc -l <"$plog")"
WORKAI_RELEASE_BINARIES="$tmp/releases.txt" PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1
[ "$(wc -l <"$plog")" = "$n" ] && grep -q 'tools: nothing missing' "$tmp/out" && ok "MacPorts second run changes nothing" || bad "MacPorts second run changes nothing"
rm "$HOME/.local/bin/workmux"
printf 'workmux darwin %s https://example.invalid/workmux.tar.gz %s\n' "$arch" "0000$sum" >"$tmp/bad.txt"
WORKAI_RELEASE_BINARIES="$tmp/bad.txt" PATH="$P" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1
[ ! -e "$HOME/.local/bin/workmux" ] && grep -q 'SHA-256 mismatch' "$tmp/out" && ok "checksum mismatch refused" || bad "checksum mismatch refused"

# --- No package manager -----------------------------------------------------
rm -rf "$HOME"; mkdir -p "$HOME"
PATH="$sys" WORKAI_OS=Darwin bash "$here/deps/install-mac.sh" >"$tmp/out" 2>&1; [ $? = 1 ] && grep -q 'install Homebrew' "$tmp/out" && ok "no package manager: says what to install" || bad "no package manager: says what to install"

# --- Ubuntu ------------------------------------------------------------------
rm -rf "$HOME"; mkdir -p "$HOME"; bin="$tmp/ubin"; mkdir -p "$bin"; alog="$tmp/apt.log"
root="$tmp/root"; mkdir -p "$root/etc"; printf 'ID=ubuntu\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' >"$root/etc/os-release"
printf '#!/bin/sh\nexec "$@"\n' >"$bin/sudo"
printf '#!/bin/sh\necho amd64\n' >"$bin/dpkg"
cat >"$tmp/curl-stub" <<STUB
#!/bin/bash
echo "curl \$*" >>"$tmp/ucurl.log"
out=""; url=""; while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; -*) ;; *) url="\$1" ;; esac; shift; done
case "\$url" in
  *workmux.tar.gz) cp "$tmp/workmux.tar.gz" "\$out" ;;
  *gitleaks.tar.gz) cp "$tmp/gitleaks.tar.gz" "\$out" ;;
  https://cli.github.com/*|https://downloads.claude.ai/keys/*) echo key >"\$out" ;;
  *) exit 22 ;;
esac
STUB
cat >"$bin/apt-get" <<STUB
#!/bin/bash
echo "apt-get \$*" >>"$alog"
[ "\$1" = install ] || exit 0
for p in "\$@"; do
  case "\$p" in
    -*|install) ;;
    ca-certificates) ;;
    curl) cp "$tmp/curl-stub" "$bin/curl"; chmod +x "$bin/curl" ;;
    gnupg) printf '#!/bin/sh\necho "fpr:::::::::31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE:"\n' >"$bin/gpg"; chmod +x "$bin/gpg" ;;
    python3) printf '#!/bin/sh\nexit 0\n' >"$bin/python3"; chmod +x "$bin/python3" ;;
    claude-code) printf '#!/bin/sh\necho claude\n' >"$bin/claude"; chmod +x "$bin/claude" ;;
    *) printf '#!/bin/sh\necho stub\n' >"$bin/\$p"; chmod +x "$bin/\$p" ;;
  esac
done
STUB
chmod +x "$bin/sudo" "$bin/dpkg" "$bin/apt-get"
mkdir -p "$tmp/gpkg"; printf '#!/bin/sh\necho gitleaks\n' >"$tmp/gpkg/gitleaks"; chmod +x "$tmp/gpkg/gitleaks"
tar -czf "$tmp/gitleaks.tar.gz" -C "$tmp/gpkg" gitleaks
gsum="$(shasum -a 256 "$tmp/gitleaks.tar.gz" | cut -d' ' -f1)"
printf 'workmux linux x86_64 https://example.invalid/workmux.tar.gz %s\ngitleaks linux x86_64 https://example.invalid/gitleaks.tar.gz %s\n' "$sum" "$gsum" >"$tmp/ureleases.txt"
U() { WORKAI_OS=Linux WORKAI_ARCH=x86_64 WORKAI_APT_ROOT="$root" WORKAI_RELEASE_BINARIES="$tmp/ureleases.txt" PATH="$bin:$HOME/.local/bin:$sys" bash "$here/deps/install-ubuntu.sh" "$@" >"$tmp/out" 2>&1; }
U --check; rc=$?
[ "$rc" = 1 ] && [ "$(grep -c '^missing ' "$tmp/out")" = "$(( $(echo "$tools" | wc -l) + 1 ))" ] && ok "ubuntu --check lists everything missing" || bad "ubuntu --check lists everything missing"
U --dry-run; [ ! -e "$alog" ] && grep -q 'apt-get install -y -q curl ca-certificates gnupg git tmux jq python3' "$tmp/out" && ok "ubuntu --dry-run prints, runs nothing" || bad "ubuntu --dry-run prints, runs nothing"
U && ok "ubuntu install exits 0" || bad "ubuntu install exits 0"
grep -q 'apt-get install -y -q curl ca-certificates gnupg git tmux jq python3$' "$alog" && ok "apt packages in one install" || bad "apt packages in one install"
grep -q 'apt-get install -y -q gh claude-code$' "$alog" && ok "gh and claude-code from their vendor repos" || bad "gh and claude-code from their vendor repos"
grep -q 'https://cli.github.com/packages stable main' "$root/etc/apt/sources.list.d/github-cli.list" 2>/dev/null && ok "GitHub apt source written" || bad "GitHub apt source written"
grep -q 'downloads.claude.ai/claude-code/apt/stable stable main' "$root/etc/apt/sources.list.d/claude-code.list" 2>/dev/null && ok "Claude Code apt source (stable) written" || bad "Claude Code apt source (stable) written"
[ -x "$HOME/.local/bin/workmux" ] && [ -x "$HOME/.local/bin/gitleaks" ] && ok "workmux and gitleaks from pinned releases" || bad "workmux and gitleaks from pinned releases"
[ -L "$CLAUDE_SKILLS_DIR/workai-backlog" ] && ok "ubuntu: skills installed" || bad "ubuntu: skills installed"
n="$(wc -l <"$alog")"
U; [ "$(wc -l <"$alog")" = "$n" ] && grep -q 'tools: nothing missing' "$tmp/out" && ok "ubuntu second run changes nothing" || bad "ubuntu second run changes nothing"
U --check && grep -q 'nothing missing' "$tmp/out" && ok "ubuntu --check reports nothing missing afterwards" || bad "ubuntu --check reports nothing missing afterwards"
rm "$bin/claude" "$root/etc/apt/sources.list.d/claude-code.list" "$root/etc/apt/keyrings/claude-code.asc"
printf '#!/bin/sh\necho "fpr:::::::::0000000000000000000000000000000000000000:"\n' >"$bin/gpg"
U; [ $? = 1 ] && grep -q 'fingerprint is not' "$tmp/out" && [ ! -e "$root/etc/apt/keyrings/claude-code.asc" ] && ok "wrong Claude Code key fingerprint refused" || bad "wrong Claude Code key fingerprint refused"
WORKAI_OS=Darwin bash "$here/deps/install-ubuntu.sh" >"$tmp/out" 2>&1; [ $? = 2 ] && ok "ubuntu script refuses macOS" || bad "ubuntu script refuses macOS"

# Both scripts read the same list: every tool has a Homebrew and an Ubuntu route.
awk '!/^#/ && NF >= 4 && ($2 == "-" || $4 == "-") { print; b=1 } END { exit b }' "$here/deps/tools.txt" >"$tmp/out" \
  && ok "every tool has a Homebrew and an Ubuntu route" || bad "every tool has a Homebrew and an Ubuntu route"

# The pinned release list covers every tool that uses it, on every platform.
for t in $(awk '!/^#/ && NF >= 4 && ($3 == "release" || $4 == "release") { print $1 }' "$here/deps/tools.txt"); do
  for plat in "darwin arm64" "darwin x86_64" "linux x86_64" "linux arm64"; do
    awk -v t="$t" -v p="$plat" '!/^#/ && ($1" "$2" "$3) == (t" "p) && length($5) == 64 { f=1 } END { exit !f }' "$here/deps/release-binaries.txt" \
      && ok "pinned $t $plat" || bad "pinned $t $plat"
  done
done

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
