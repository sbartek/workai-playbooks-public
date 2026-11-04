#!/usr/bin/env bash
# Tests for tools/workai-secret against fake backends (security, secret-tool,
# pass, systemd-creds). Every fake logs its argv; a canary value must never
# show up there, nor in anything but `get` output and the store itself.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
ws="$here/tools/workai-secret/workai-secret"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

export FAKE_STORE="$tmp/store" PASSWORD_STORE_DIR="$tmp/store/pass"
mkdir -p "$FAKE_STORE/kc" "$FAKE_STORE/st" "$tmp/bin"
log="$FAKE_STORE/argv.log"

cat >"$tmp/bin/security" <<'EOF'
#!/usr/bin/env bash
echo "security $*" >>"$FAKE_STORE/argv.log"
key() { printf '%s' "$1" | tr '/' '%'; }
case "$1" in
  -i) while read -r line; do
        set -- $line; s=""; x=""
        while [ $# -gt 0 ]; do case "$1" in -s) s="$2"; shift ;; -X) x="$2"; shift ;; esac; shift; done
        printf "$(printf '%s' "$x" | sed 's/../\\x&/g')" >"$FAKE_STORE/kc/$(key "$s")"
      done ;;
  find-generic-password) shift; while [ $# -gt 0 ]; do [ "$1" = -s ] && s="$2"; shift; done
      f="$FAKE_STORE/kc/$(key "$s")"; [ -f "$f" ] || exit 44; cat "$f"; echo ;;
  delete-generic-password) shift; while [ $# -gt 0 ]; do [ "$1" = -s ] && s="$2"; shift; done
      f="$FAKE_STORE/kc/$(key "$s")"; [ -f "$f" ] || exit 44; rm "$f" ;;
  dump-keychain) for f in "$FAKE_STORE"/kc/*; do [ -f "$f" ] || continue
        printf '    "svce"<blob>="%s"\n' "$(basename "$f" | tr '%' '/')"; done
      printf '    "svce"<blob>="someone-else"\n' ;;
esac
EOF
cat >"$tmp/bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
echo "secret-tool $*" >>"$FAKE_STORE/argv.log"
name() { while [ $# -gt 0 ]; do [ "$1" = name ] && { printf '%s' "$2" | tr '/' '%'; return; }; shift; done; }
f="$FAKE_STORE/st/$(name "$@")"
case "$1" in
  store) cat >"$f" ;;
  lookup) [ -f "$f" ] || exit 1; cat "$f" ;;
  clear) rm -f "$f" ;;
  search) for g in "$FAKE_STORE"/st/*; do [ -f "$g" ] || continue
            echo "attribute.app = workai" >&2; echo "attribute.name = $(basename "$g" | tr '%' '/')" >&2; done ;;
esac
EOF
cat >"$tmp/bin/pass" <<'EOF'
#!/usr/bin/env bash
echo "pass $*" >>"$FAKE_STORE/argv.log"
case "$1" in
  insert) p="${!#}"; mkdir -p "$(dirname "$PASSWORD_STORE_DIR/$p")"; cat >"$PASSWORD_STORE_DIR/$p.gpg" ;;
  show) [ -f "$PASSWORD_STORE_DIR/$2.gpg" ] || exit 1; cat "$PASSWORD_STORE_DIR/$2.gpg" ;;
  rm) p="${!#}"; [ -f "$PASSWORD_STORE_DIR/$p.gpg" ] || exit 1; rm "$PASSWORD_STORE_DIR/$p.gpg" ;;
esac
EOF
cat >"$tmp/bin/systemd-creds" <<'EOF'
#!/usr/bin/env bash
echo "systemd-creds $*" >>"$FAKE_STORE/argv.log"
[ "$1" = encrypt ] || exit 1
{ printf 'ENC:'; cat; } >"${!#}"
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"

canary='cAnArY-91c2 "q" $x \b'
out="$tmp/out"

for b in keychain secret-tool pass; do
  export WORKAI_SECRET_BACKEND=$b
  : >"$out"
  "$ws" backend 2>>"$out" | grep -q "^$b (forced" && ok "$b: forced backend" || bad "$b: forced backend"
  printf '%s\n' "$canary" | "$ws" set app/token >>"$out" 2>&1 && ok "$b: set from stdin" || bad "$b: set from stdin"
  [ "$("$ws" get app/token 2>>"$out")" = "$canary" ] && ok "$b: get returns the value" || bad "$b: get returns the value"
  printf 'second\n' | "$ws" set other.key >>"$out" 2>&1
  [ "$("$ws" list 2>>"$out" | tr '\n' ' ')" = "app/token other.key " ] && ok "$b: list shows names only" || bad "$b: list shows names only"
  [ "$("$ws" run --only app/token -- printenv APP_TOKEN 2>>"$out")" = "$canary" ] && ok "$b: run exports APP_TOKEN" || bad "$b: run exports APP_TOKEN"
  [ "$("$ws" run -- printenv OTHER_KEY 2>>"$out")" = second ] && ok "$b: run without --only exports all" || bad "$b: run without --only exports all"
  printf 'app/token MY_TOKEN\n' >"$tmp/map"
  [ "$(WORKAI_SECRET_MAP="$tmp/map" "$ws" run --only app/token -- printenv MY_TOKEN 2>>"$out")" = "$canary" ] && ok "$b: map file renames the env var" || bad "$b: map file renames the env var"
  printf 'new\n' | "$ws" set app/token >>"$out" 2>&1
  [ "$("$ws" get app/token 2>>"$out")" = new ] && ok "$b: set overwrites" || bad "$b: set overwrites"
  printf '%s\n' "$canary" | "$ws" set app/token >>"$out" 2>&1
  "$ws" rm other.key >>"$out" 2>&1 && ! "$ws" get other.key >/dev/null 2>&1 && ok "$b: rm" || bad "$b: rm"
  "$ws" rm other.key >/dev/null 2>&1 && bad "$b: rm of a missing secret fails" || ok "$b: rm of a missing secret fails"
  "$ws" run --only missing -- true 2>/dev/null && bad "$b: run with a missing secret fails" || ok "$b: run with a missing secret fails"
  grep -qF "cAnArY" "$out" && bad "$b: canary leaked to output" || ok "$b: canary not in any output"
done

grep -qF "cAnArY" "$log" && bad "canary in a backend's argv" || ok "canary never in argv"
grep -qF "$(printf '%s' cAnArY | od -An -tx1 | tr -d ' \n')" "$log" && bad "canary hex in argv" || ok "canary hex never in argv"

export WORKAI_SECRET_BACKEND=keychain
printf 'caf\xc3\xa9\n' | "$ws" set x/y 2>/dev/null && bad "non-ASCII value refused" || ok "non-ASCII value refused"
printf 'a\nb\n' | "$ws" set x/y 2>/dev/null && bad "multi-line value refused" || ok "multi-line value refused"
printf '' | "$ws" set x/y 2>/dev/null && bad "empty value refused" || ok "empty value refused"
for n in Bad /abs a/../b a//b trail/ ''; do
  printf 'v\n' | "$ws" set "$n" 2>/dev/null && bad "name '$n' refused" || ok "name '$n' refused"
done
printf 'v\r\n' | "$ws" set crlf/ok 2>/dev/null && [ "$("$ws" get crlf/ok)" = v ] && ok "CRLF line ending dropped" || bad "CRLF line ending dropped"
WORKAI_SECRET_BACKEND=nope "$ws" list 2>/dev/null && bad "unknown backend refused" || ok "unknown backend refused"
"$ws" frobnicate 2>/dev/null; [ $? = 2 ] && ok "unknown command is a usage error" || bad "unknown command is a usage error"

# export-systemd writes through systemd-creds, value on stdin only
export WORKAI_CREDSTORE="$tmp/credstore"; mkdir -p "$WORKAI_CREDSTORE"
"$ws" export-systemd app/token factory-api.service 2>"$out" \
  && [ "$(cat "$WORKAI_CREDSTORE/app-token")" = "ENC:$canary" ] && ok "export-systemd encrypts to the credstore" || bad "export-systemd encrypts to the credstore"
grep -q 'LoadCredentialEncrypted=app-token:' "$out" && ok "export-systemd prints the unit line" || bad "export-systemd prints the unit line"
grep -qF "cAnArY" "$log" && bad "canary in argv after export-systemd" || ok "canary not in argv after export-systemd"

# installed as a symlink elsewhere, the map file next to the real script is found
ln -s "$ws" "$tmp/bin/workai-secret"
[ "$(cd / && workai-secret backend)" = "keychain (forced by WORKAI_SECRET_BACKEND)" ] && ok "runs through a symlink" || bad "runs through a symlink"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
