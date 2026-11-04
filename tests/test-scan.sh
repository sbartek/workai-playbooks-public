#!/usr/bin/env bash
# Tests for the pre-push scan (workai-new-project/scan.py, push-hub.sh,
# install-scan-hook.sh). Fake secrets are assembled at run time so this file
# itself never looks like one.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
skill="$here/skills/workai-new-project"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export WORKAI_SCAN_NO_GITLEAKS=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -f "$tmp/out" ] && sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }

newrepo() { rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q; }
commit() { git -C "$1" add -A; git -C "$1" commit -q -m "$2"; }
scan() { python3 "$skill/scan.py" "$1" >"$tmp/out" 2>&1; }

pk="-----BEGIN OPENSSH ""PRIVATE KEY-----"
ghtok="ghp_$(printf 'a1B2c3D4e5%.0s' 1 2 3 4)"
dni_ok="12345678""Z"; dni_bad="12345678""A"

r="$tmp/clean"; newrepo "$r"; echo "# notes" >"$r/README.md"; commit "$r" one
scan "$r" && ok "clean repo passes" || bad "clean repo passes"
newrepo "$tmp/empty"; scan "$tmp/empty" && ok "repo without commits passes" || bad "repo without commits passes"

r="$tmp/key"; newrepo "$r"; printf '%s\nabc\n' "$pk" >"$r/notes.md"; commit "$r" one
scan "$r"; [ $? = 1 ] && grep -q 'notes.md:1  secret/private-key' "$tmp/out" && ok "private key found" || bad "private key found"
echo "# fine" >"$r/notes.md"; commit "$r" two
scan "$r"; [ $? = 1 ] && grep -q 'secret/private-key' "$tmp/out" && ok "secret removed later is still found (history)" || bad "secret removed later is still found (history)"

r="$tmp/tok"; newrepo "$r"; echo "token: $ghtok" >"$r/a.md"; commit "$r" one
scan "$r"; [ $? = 1 ] && grep -q 'secret/github-token' "$tmp/out" && ok "GitHub token found" || bad "GitHub token found"
grep -q "$ghtok" "$tmp/out" && bad "secret value never printed" || ok "secret value never printed"

r="$tmp/assign"; newrepo "$r"
printf 'password = changeme\napi_key = "your-api-key-here"\nsee the stock password\n' >"$r/a.md"; commit "$r" one
scan "$r" && ok "placeholders and prose are not secrets" || bad "placeholders and prose are not secrets"
echo "DB_PASSWORD=Xk29fj$((7*13))qpLm4" >"$r/.envrc"; commit "$r" two
scan "$r"; [ $? = 1 ] && grep -q '.envrc:1  secret/assigned-secret' "$tmp/out" && ok "assigned secret found" || bad "assigned secret found"

r="$tmp/files"; newrepo "$r"; mkdir -p "$r/docs"
for f in docs/03_DNI_Ejemplo.pdf docs/02_CertificadoNacimiento_Ejemplo.pdf docs/firma_ejemplo.png docs/passport-scan.jpg cert.p12 .env; do echo x >"$r/$f"; done
for f in docs/kindness.pdf docs/notes-tie.md .env.example docs/consentimiento.pdf; do echo x >"$r/$f"; done
commit "$r" one
scan "$r"
for f in docs/03_DNI_Ejemplo.pdf docs/02_CertificadoNacimiento_Ejemplo.pdf docs/firma_ejemplo.png docs/passport-scan.jpg; do
  grep -q "^$f  identity/identity-document-name" "$tmp/out" && ok "identity file: $f" || bad "identity file: $f"
done
for f in cert.p12 .env; do grep -q "^$f  secret/credential-file" "$tmp/out" && ok "credential file: $f" || bad "credential file: $f"; done
for f in docs/kindness.pdf docs/notes-tie.md .env.example docs/consentimiento.pdf; do
  grep -q "^$f " "$tmp/out" && bad "not flagged: $f" || ok "not flagged: $f"
done

r="$tmp/dni"; newrepo "$r"; echo "NIE/DNI $dni_bad and 2026-10-24" >"$r/a.md"; commit "$r" one
scan "$r" && ok "DNI-shaped number with a wrong control letter passes" || bad "DNI-shaped number with a wrong control letter passes"
echo "DNI $dni_ok" >"$r/b.md"; commit "$r" two
scan "$r"; [ $? = 1 ] && grep -q 'b.md:1  identity/dni-nie-number' "$tmp/out" && ok "valid DNI number found" || bad "valid DNI number found"
printf 'b.md dni-nie-number   # their own, OK by the user\n' >"$r/.workai-scan-allow"
scan "$r" && ok ".workai-scan-allow suppresses a listed hit" || bad ".workai-scan-allow suppresses a listed hit"
printf 'b.md private-key\n' >"$r/.workai-scan-allow"
scan "$r"; [ $? = 1 ] && ok "allow line for another rule does not suppress" || bad "allow line for another rule does not suppress"

python3 "$skill/scan.py" "$tmp/nope" >"$tmp/out" 2>&1; [ $? = 2 ] && ok "not a repo: exit 2" || bad "not a repo: exit 2"

# push-hub.sh with a fake gh that records its arguments.
mkdir -p "$tmp/bin"; printf '#!/bin/sh\necho "$@" >"%s/gh-called"\n' "$tmp" >"$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH" bash "$skill/push-hub.sh" "$tmp/key" sbartek/99-x >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$tmp/gh-called" ] && grep -q 'STOP' "$tmp/out" && ok "push-hub stops on a hit, gh never called" || bad "push-hub stops on a hit, gh never called"
PATH="$tmp/bin:$PATH" bash "$skill/push-hub.sh" "$tmp/clean" sbartek/99-x >"$tmp/out" 2>&1
grep -qx 'repo create sbartek/99-x --private --source='"$tmp/clean"' --push' "$tmp/gh-called" 2>/dev/null && ok "push-hub creates a private repo when clean" || bad "push-hub creates a private repo when clean"
bash "$skill/push-hub.sh" "$tmp/clean" >"$tmp/out" 2>&1; [ $? = 2 ] && ok "push-hub needs OWNER/NAME" || bad "push-hub needs OWNER/NAME"

# The pre-push hook, through new-project.sh, against a local bare remote.
export WORKAI_ROOT="$tmp/workai"; mkdir -p "$WORKAI_ROOT/projects" "$WORKAI_ROOT/archives"
NO_REGISTER=1 bash "$here/skills/workai-new-project/new-project.sh" scan-me "Scan Me" >"$tmp/out" 2>&1 || bad "new-project for hook test"
hub="$WORKAI_ROOT/projects/01-scan-me"
[ -x "$hub/.git/hooks/pre-push" ] && [ -f "$hub/.git/hooks/workai-scan.py" ] && ok "new-project installs the pre-push hook" || bad "new-project installs the pre-push hook"
git init -q --bare "$tmp/remote.git"; git -C "$hub" remote add origin "$tmp/remote.git"
git -C "$hub" push -q origin HEAD:refs/heads/main >"$tmp/out" 2>&1 && ok "clean hub pushes through the hook" || bad "clean hub pushes through the hook"
echo x >"$hub/notes/05_DNI_Ejemplo.pdf"; commit "$hub" scan
git -C "$hub" push -q origin HEAD:refs/heads/main >"$tmp/out" 2>&1 && bad "hook stops a push with an identity scan" || ok "hook stops a push with an identity scan"
[ "$(git -C "$tmp/remote.git" rev-parse main)" = "$(git -C "$hub" rev-parse HEAD~1)" ] && ok "nothing reached the remote" || bad "nothing reached the remote"
printf '#!/bin/sh\necho mine\n' >"$tmp/clean/.git/hooks/pre-push"
bash "$skill/install-scan-hook.sh" "$tmp/clean" >"$tmp/out" 2>&1 && bad "hook installer leaves a foreign hook alone" || ok "hook installer leaves a foreign hook alone"
# Git LFS's own hook (card 01-141): the scan goes first, LFS stays, twice is stable.
printf '#!/bin/sh\ncommand -v git-lfs >/dev/null 2>&1 || { exit 2; }\ngit lfs pre-push "$@"\n' >"$tmp/clean/.git/hooks/pre-push"
bash "$skill/install-scan-hook.sh" "$tmp/clean" >"$tmp/out" 2>&1 && bash "$skill/install-scan-hook.sh" "$tmp/clean" >>"$tmp/out" 2>&1 \
  && grep -q '# workai pre-push scan' "$tmp/clean/.git/hooks/pre-push" \
  && [ "$(grep -c '^git lfs pre-push "\$@"$' "$tmp/clean/.git/hooks/pre-push")" = 1 ] \
  && [ "$(grep -n 'workai-scan.py' "$tmp/clean/.git/hooks/pre-push" | head -1 | cut -d: -f1)" -lt "$(grep -n '^git lfs pre-push' "$tmp/clean/.git/hooks/pre-push" | cut -d: -f1)" ] \
  && ok "hook installer chains in front of Git LFS's hook" || { bad "hook installer chains in front of Git LFS's hook"; cat "$tmp/clean/.git/hooks/pre-push"; }

# A tracked hooks folder (core.hooksPath inside the work tree) gets no untracked copy.
mkdir -p "$tmp/clean/.githooks"; git -C "$tmp/clean" config core.hooksPath .githooks
bash "$skill/install-scan-hook.sh" "$tmp/clean" >"$tmp/out" 2>&1 && bad "tracked hooks folder refused" \
  || { [ ! -e "$tmp/clean/.githooks/pre-push" ] && [ ! -e "$tmp/clean/.githooks/workai-scan.py" ] && ok "tracked hooks folder refused, nothing copied" || bad "tracked hooks folder refused"; }
git -C "$tmp/clean" config --unset core.hooksPath
[ -x "$here/.githooks/pre-push" ] && grep -q '# workai pre-push scan' "$here/.githooks/pre-push" && ok "this repo tracks its own pre-push scan" || bad "this repo tracks its own pre-push scan"

# This repo itself (its whole history) must scan clean.
scan "$here" && ok "workai-playbooks scans clean" || bad "workai-playbooks scans clean"

[ "$fails" -eq 0 ] && echo "all tests pass" || { echo "$fails test(s) failed"; exit 1; }
