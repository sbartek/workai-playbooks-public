#!/usr/bin/env bash
# Tests for tools/workai-board/launchagent.sh with a fake launchctl.
# The script is copied into a throwaway git repo; HOME, the LaunchAgents and
# Logs folders are throwaway; the real launchctl is never called.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
LABEL=com.bartek.workai-board-web

# Throwaway repo with the script and a fake venv python.
repo="$tmp/repo"; bd="$repo/tools/workai-board"; mkdir -p "$bd/.venv/bin"
cp "$here/tools/workai-board/launchagent.sh" "$bd/"
printf '#!/bin/sh\nexit 0\n' >"$bd/.venv/bin/python"; chmod +x "$bd/.venv/bin/python"
git -C "$repo" init -q -b main
git -C "$repo" -c user.name=t -c user.email=t@t add tools/workai-board/launchagent.sh
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init
la="$bd/launchagent.sh"

# Fake launchctl: logs every call; print succeeds while "loaded".
bin="$tmp/bin"; mkdir -p "$bin"; log="$tmp/launchctl.log"; state="$tmp/loaded"
cat >"$bin/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >>"$log"
case "\$1" in
  print) [ -e "$state" ] || exit 113; echo "	state = running"; echo "	pid = 4242" ;;
  bootstrap) [ -e "$state" ] && exit 5; [ -f "\$3" ] || exit 2; cp "\$3" "$state" ;;
  bootout) [ -e "$state" ] || exit 3; rm -f "$state" ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$bin/launchctl"
export PATH="$bin:$PATH" HOME="$tmp/home" WORKAI_OS=Darwin; mkdir -p "$HOME"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
uid="$(id -u)"
calls() { if [ -e "$log" ]; then grep -c -- "$1" "$log"; else echo 0; fi; }

# --- plist only --------------------------------------------------------------
bash "$la" plist >"$tmp/out" 2>&1
[ ! -e "$log" ] && grep -q "<string>$LABEL</string>" "$tmp/out" && ok "plist prints, calls no launchctl" || bad "plist prints, calls no launchctl"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$tmp/out" >/dev/null 2>&1 && ok "plist lints" || bad "plist lints"
fi

# --- install -----------------------------------------------------------------
bash "$la" install >"$tmp/out" 2>&1 && ok "install exits 0" || bad "install exits 0"
[ -f "$plist" ] && ok "plist written to ~/Library/LaunchAgents" || bad "plist written to ~/Library/LaunchAgents"
grep -q "launchctl bootstrap gui/$uid $plist" "$log" && ok "bootstrap in gui/<uid>" || bad "bootstrap in gui/<uid>"
for want in "<string>$bd/.venv/bin/python</string>" '<string>workai_board</string>' '<string>--web</string>' \
            '<string>8646</string>' '<key>RunAtLoad</key>' '<key>KeepAlive</key>' \
            "<string>$HOME/Library/Logs/workai-board-web.log</string>" "<string>$bd</string>"; do
  grep -qF -- "$want" "$plist" && ok "plist has $want" || { cp "$plist" "$tmp/out"; bad "plist has $want"; }
done
grep -q '0\.0\.0\.0\|--host' "$plist" && { cp "$plist" "$tmp/out"; bad "no host other than 127.0.0.1"; } || ok "no host other than 127.0.0.1"
[ -d "$HOME/Library/Logs" ] && ok "log folder created" || bad "log folder created"

n="$(calls bootstrap)"
bash "$la" install >"$tmp/out" 2>&1
[ "$(calls bootstrap)" = "$n" ] && [ "$(calls bootout)" = 0 ] && grep -q 'nothing to do' "$tmp/out" \
  && ok "second install changes nothing" || bad "second install changes nothing"

bash "$la" install --port 8650 >"$tmp/out" 2>&1
grep -q '<string>8650</string>' "$plist" && [ "$(calls bootout)" = 1 ] && [ "$(calls bootstrap)" = $((n + 1)) ] \
  && ok "new port: bootout, rewrite, bootstrap" || bad "new port: bootout, rewrite, bootstrap"

bash "$la" status >"$tmp/out" 2>&1 && grep -qx "$LABEL: loaded, pid 4242" "$tmp/out" && ok "status shows the pid" || bad "status shows the pid"

bash "$la" install --port abc >"$tmp/out" 2>&1; [ $? = 2 ] && ok "bad port refused" || bad "bad port refused"
bash "$la" install --port 70000 >"$tmp/out" 2>&1; [ $? = 2 ] && ok "port out of range refused" || bad "port out of range refused"
grep -q '<string>8650</string>' "$plist" && ok "refused install leaves the plist" || bad "refused install leaves the plist"

# --- uninstall ---------------------------------------------------------------
bash "$la" uninstall >"$tmp/out" 2>&1 && ok "uninstall exits 0" || bad "uninstall exits 0"
[ ! -e "$plist" ] && [ ! -e "$state" ] && ok "uninstall unloads and removes the plist" || bad "uninstall unloads and removes the plist"
bash "$la" uninstall >"$tmp/out" 2>&1 && ok "uninstall twice is fine" || bad "uninstall twice is fine"
bash "$la" status >"$tmp/out" 2>&1; [ $? = 3 ] && ok "status exits 3 when not installed" || bad "status exits 3 when not installed"

# --- refusals ----------------------------------------------------------------
before="$(calls .)"
WORKAI_OS=Linux bash "$la" install >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'Mac only' "$tmp/out" && [ "$(calls .)" = "$before" ] && ok "Linux refused, nothing called" || bad "Linux refused, nothing called"

git -C "$repo" worktree add -q "$tmp/wt" -b card/x 2>/dev/null
mkdir -p "$tmp/wt/tools/workai-board/.venv/bin"; cp "$bd/.venv/bin/python" "$tmp/wt/tools/workai-board/.venv/bin/"
bash "$tmp/wt/tools/workai-board/launchagent.sh" install >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'worktree' "$tmp/out" && [ ! -e "$plist" ] && ok "install from a worktree refused" || bad "install from a worktree refused"
bash "$tmp/wt/tools/workai-board/launchagent.sh" install --allow-worktree >"$tmp/out" 2>&1 && [ -f "$plist" ] \
  && ok "--allow-worktree installs" || bad "--allow-worktree installs"
bash "$la" uninstall >"$tmp/out" 2>&1

rm "$bd/.venv/bin/python"
bash "$la" install >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'uv sync' "$tmp/out" && [ ! -e "$plist" ] && ok "missing venv refused with a hint" || bad "missing venv refused with a hint"

[ "$fails" = 0 ] && echo "all launchagent tests passed" || echo "$fails launchagent test(s) failed"
[ "$fails" = 0 ]
