#!/usr/bin/env bash
# Review a diff with opencode and a zero-retention free model; write one
# Markdown comment (card 01-084). Used by .github/workflows/ai-review.yml and
# runnable by hand in a checkout:
#
#   scripts/opencode-review.sh <diff-file> <out.md> [models]
#
# Models: an ordered list (spaces or commas), from the argument, else
# $AI_REVIEW_MODELS, else $AI_REVIEW_MODEL, else
# "opencode/deepseek-v4.1-flash-free opencode/glm-5.3-flash-free". The first
# model is tried; only when opencode fails with Zen's free-quota error ("Free
# usage limit reached" in an ERROR line) is the next one tried (card 01-183).
# Any other failure stops at once (exit 1). Every model in the list hitting
# the quota: exit 4, no review written (the workflow then skips green).
# Only the zero-retention free models are accepted, written exactly as
# opencode/deepseek-v4.1-flash-free or opencode/glm-5.3-flash-free (Zen docs,
# checked 2026-10-27, card 01-183; hub note notes/opencode-free-models.md):
# any other model anywhere in the list exits 2 before anything is sent.
# The comment names the model that wrote it. The key, if any, comes
# from OPENCODE_API_KEY; a review whose text contains the key (plain,
# base64, URL-safe base64 or hex, any case) is never written: exit 1.
#
# Run it inside a git checkout of the PR head. In CI the workflow runs the
# copy of this script from the BASE commit, never the PR's own version. The
# agent works on a copy of HEAD's tracked files (written from the blobs, so
# no .gitattributes rule hides or rewrites files; no symlinks) in a temporary
# folder, never on the checkout: there it may only read, glob and grep; every
# other action (shell, edit, web, external directories, subagents, skills,
# questions) is denied by an opencode.jsonc written into the copy, replacing
# any opencode config the PR brings. opencode gets a throwaway HOME and XDG
# dirs (no user config or plugins), and on macOS runs under sandbox-exec with
# the caller's real HOME denied (except the folder of the opencode binary). Exit 1 if opencode fails or returns no text.
#
# opencode never gets the key (card 01-157): it is neither in opencode's
# environment nor in its config. With OPENCODE_API_KEY set, a small local
# proxy (127.0.0.1, random port; key and token read from stdin, never argv
# or environment; non-dumpable on Linux) holds it: opencode's config
# points the `opencode` provider at the proxy with a random per-run token
# (the proxy refuses any other caller), the proxy forwards only /zen/...
# requests to https://opencode.ai with the real key,
# and opencode runs with OPENCODE_API_KEY removed from its environment.
# With AI_REVIEW_USER=<user> (the Linux CI runner; needs `sudo -n`),
# opencode also runs as that other, unprivileged user with a minimal
# environment (PATH, LANG, and HOME/XDG dirs inside the temp dir): it cannot
# read this script's or the proxy's /proc/*/environ or memory (other uid)
# nor the caller's private files; the temp files it may not see are mode
# 600/700. Without AI_REVIEW_USER (macOS, by hand) opencode shares the
# caller's uid, which could still read the key from this script's process.
# AI_REVIEW_UPSTREAM overrides the upstream URL (tests only).
set -u -o pipefail
diff_file="${1:?usage: opencode-review.sh <diff-file> <out.md> [models]}"
out="${2:?usage: opencode-review.sh <diff-file> <out.md> [models]}"
model_list="${3:-${AI_REVIEW_MODELS:-${AI_REVIEW_MODEL:-opencode/deepseek-v4.1-flash-free opencode/glm-5.3-flash-free}}}"
max_bytes="${AI_REVIEW_MAX_DIFF_BYTES:-200000}"
oc="${OPENCODE_BIN:-opencode}"
IFS=', ' read -r -a models <<<"$model_list"
[ "${#models[@]}" -gt 0 ] || { echo "opencode-review: no model given" >&2; exit 2; }
for model in "${models[@]}"; do
  case "$model" in
    opencode/deepseek-v4.1-flash-free|opencode/glm-5.3-flash-free) ;;
    *) echo "opencode-review: $model is not a zero-retention free model; use opencode/deepseek-v4.1-flash-free or opencode/glm-5.3-flash-free" >&2
       exit 2 ;;
  esac
done
# The one failure that moves on to the next model: Zen's free quota.
quota_msg='Free usage limit reached'

[ -f "$diff_file" ] || { echo "opencode-review: no diff file $diff_file" >&2; exit 2; }
if [ ! -s "$diff_file" ]; then
  printf '<!-- ai-review:opencode -->\n### AI review (opencode)\n\nEmpty diff: nothing to review.\n' >"$out"
  exit 0
fi

review_user="${AI_REVIEW_USER:-}"
if [ -n "$review_user" ]; then
  id -u "$review_user" >/dev/null 2>&1 || { echo "opencode-review: AI_REVIEW_USER $review_user does not exist" >&2; exit 2; }
  [ "$(id -u "$review_user")" != "$(id -u)" ] && [ "$(id -u "$review_user")" != 0 ] ||
    { echo "opencode-review: AI_REVIEW_USER must be another, non-root user" >&2; exit 2; }
  sudo -n -u "$review_user" true 2>/dev/null || { echo "opencode-review: cannot sudo -n -u $review_user" >&2; exit 2; }
fi
tmp="$(mktemp -d)"
proxy_pid=""
cleanup() {
  [ -n "$proxy_pid" ] && { kill "$proxy_pid"; wait "$proxy_pid"; } 2>/dev/null
  [ -n "$review_user" ] && sudo -n chown -R "$(id -u)" "$tmp" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
# opencode's server log is chatty: show its ERROR lines, else the last lines.
show_errors() {
  grep 'level=ERROR' "$tmp/run.err" | cut -c1-600 >&2 || tail -n 20 "$tmp/run.err" >&2
}
note=""
if [ "$(wc -c <"$diff_file")" -gt "$max_bytes" ]; then
  head -c "$max_bytes" "$diff_file" >"$tmp/pr.diff"
  note="The diff was cut to its first $max_bytes bytes; the rest was not reviewed."
else
  cp "$diff_file" "$tmp/pr.diff"
fi

diff_abs="$tmp/pr.diff"
mkdir "$tmp/src"
# Every tracked file of HEAD, written straight from its blobs. Not `git
# archive` (export-ignore could hide files) and not checkout-index (smudge
# filters, working-tree-encoding): .gitattributes plays no part. Symlinks
# (they could point the read tool at a real file outside the copy) and
# submodules are skipped.
python3 - "$tmp/src" <<'EOF' 2>"$tmp/git.err" || {
import os, subprocess, sys
dest = sys.argv[1]
tree = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", "HEAD"],
                      capture_output=True, check=True).stdout
cat = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
for entry in filter(None, tree.split(b"\0")):
    meta, path = entry.split(b"\t", 1)
    mode, kind, sha = meta.split()
    if kind != b"blob" or mode not in (b"100644", b"100755"):
        continue
    cat.stdin.write(sha + b"\n"); cat.stdin.flush()
    size = int(cat.stdout.readline().split()[2])
    data = cat.stdout.read(size); cat.stdout.read(1)
    rel = os.path.normpath(os.fsdecode(path))
    if rel.startswith("..") or os.path.isabs(rel):
        continue
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(data)
    if mode == b"100755":
        os.chmod(out, 0o755)
cat.stdin.close(); cat.wait()
EOF
  echo "opencode-review: not in a git checkout (git ls-tree HEAD failed)" >&2; exit 2; }
# The PR's own opencode config could grant the shell: drop it, use ours.
rm -rf "$tmp/src/opencode.json" "$tmp/src/opencode.jsonc" "$tmp/src/.opencode"
# The key stays with a local proxy; opencode only ever sees a dummy key.
provider=""
if [ -n "${OPENCODE_API_KEY:-}" ]; then
  cat >"$tmp/proxy.py" <<'EOF'
import hmac, http.client, http.server, os, posixpath, sys, urllib.parse
key = sys.stdin.readline().strip()
token = sys.stdin.readline().strip()
sys.stdin.close()
try:  # Linux: no core dumps, no same-uid ptrace or /proc/<pid>/mem|environ
    import ctypes
    ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)  # PR_SET_DUMPABLE = 4
except (AttributeError, OSError):
    pass
up = urllib.parse.urlsplit(os.environ.get("UPSTREAM") or "https://opencode.ai")
DROP = {"connection", "keep-alive", "proxy-authorization", "proxy-connection", "te",
        "trailer", "transfer-encoding", "upgrade", "host", "content-length",
        "authorization", "x-api-key", "accept-encoding"}
class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def forward(self):
        if not hmac.compare_digest(self.headers.get("authorization") or "", "Bearer " + token):
            self.send_error(401, "unknown caller"); return
        # Judge the decoded path (no %2e%2e tricks); forward it only if it is
        # plainly under /zen/ and has nothing to decode.
        raw = self.path.split("?", 1)[0]
        dec = urllib.parse.unquote(raw)
        if (dec != raw or not raw.startswith("/zen/") or ".." in dec.split("/")
                or posixpath.normpath(dec) + ("/" if dec.endswith("/") else "") != dec):
            self.send_error(403, "only /zen/ is forwarded"); return
        if self.headers.get("transfer-encoding"):
            self.send_error(411); return
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROP}
        headers["Authorization"] = "Bearer " + key
        headers["Accept-Encoding"] = "identity"
        conn = (http.client.HTTPSConnection if up.scheme == "https" else http.client.HTTPConnection)(up.netloc, timeout=600)
        try:
            conn.request(self.command, up.path.rstrip("/") + self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except OSError as e:
            self.send_error(502, "upstream " + type(e).__name__); return
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in DROP:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.close_connection = True
        conn.close()
    do_GET = do_POST = forward
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
with open(sys.argv[1] + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
server.serve_forever()
EOF
  proxy_token="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
  # printf is a builtin: the key never appears in any process's argv.
  printf '%s\n%s\n' "$OPENCODE_API_KEY" "$proxy_token" |
    env -i PATH="$PATH" UPSTREAM="${AI_REVIEW_UPSTREAM:-}" \
    python3 -I "$tmp/proxy.py" "$tmp/proxy.port" >/dev/null 2>"$tmp/proxy.err" &
  proxy_pid=$!
  for _ in $(seq 1 100); do [ -s "$tmp/proxy.port" ] && break; sleep 0.1; done
  [ -s "$tmp/proxy.port" ] || { echo "opencode-review: the key proxy did not start" >&2; cat "$tmp/proxy.err" >&2; exit 1; }
  chmod 600 "$tmp/proxy.py" "$tmp/proxy.port" "$tmp/proxy.err"
  provider="  \"provider\": { \"opencode\": { \"options\": { \"baseURL\": \"http://127.0.0.1:$(cat "$tmp/proxy.port")/zen/v1\", \"apiKey\": \"$proxy_token\" } } },"
fi
cat >"$tmp/src/opencode.jsonc" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
$provider
  "permissions": [
    { "action": "*", "resource": "*", "effect": "deny" },
    { "action": "read", "resource": "*", "effect": "allow" },
    { "action": "glob", "resource": "*", "effect": "allow" },
    { "action": "grep", "resource": "*", "effect": "allow" },
    { "action": "external_directory", "resource": "*", "effect": "deny" }
  ]
}
EOF

prompt='You review a pull request of this repository. The attached file is its
unified diff; the repository at the PR head is the current directory, and you
may read files in it for context (README.md, CHANGELOG.md, skills/*/SKILL.md
hold the conventions). You cannot run commands, edit files or ask questions.

Report only real problems in the changed lines: bugs, wrong or broken
behaviour, security issues, a test or doc that no longer matches the code,
breaks of the repo conventions. For each finding give: `path:line`, one
severity word (bug, risk, docs, nit), what is wrong and why, and a fix in one
or two sentences. At most 10 findings, most important first. No praise, no
restating of the diff. If you find nothing worth fixing, answer exactly
"No issues found." Answer in Markdown, in English.'

# No user config, plugins or login: a throwaway HOME and XDG dirs.
real_home="${HOME:-}"
mkdir -p "$tmp/home" "$tmp/xdg/config" "$tmp/xdg/data" "$tmp/xdg/state" "$tmp/xdg/cache"
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg/config" XDG_DATA_HOME="$tmp/xdg/data" \
  XDG_STATE_HOME="$tmp/xdg/state" XDG_CACHE_HOME="$tmp/xdg/cache"
# macOS: the OS sandbox denies the caller's real HOME (reads and writes).
sandbox=()
if command -v sandbox-exec >/dev/null 2>&1 && [ -n "$real_home" ] && [ "$real_home" != / ]; then
  rh="$(cd "$real_home" 2>/dev/null && pwd -P || printf '%s' "$real_home")"
  case "$(cd "$tmp" && pwd -P)/" in
    "$rh"/*) echo "opencode-review: temp dir $tmp is inside HOME; set TMPDIR elsewhere" >&2; exit 2 ;;
  esac
  sbq() { local v="${1//\\/\\\\}"; printf '"%s"' "${v//\"/\\\"}"; }
  profile="(version 1)(allow default)(deny file-read* file-write* (subpath $(sbq "$rh")))"
  # opencode itself may live in HOME (~/.opencode/bin, an npm prefix): let
  # the sandbox read the folder of its real binary, nothing else of HOME.
  ocdir="$(python3 -c 'import os,shutil,sys; p=shutil.which(sys.argv[1]); print(os.path.dirname(os.path.realpath(p)) if p else "")' "$oc")"
  case "$ocdir/" in
    "$rh"/?*/) profile="$profile(allow file-read* (subpath $(sbq "$ocdir")))" ;;
  esac
  sandbox=(sandbox-exec -p "$profile")
fi

# How opencode is started: never with the key in its environment; on Linux
# CI as the separate review user with a minimal environment.
if [ -n "$review_user" ]; then
  ocpath="$(command -v "$oc")" || { echo "opencode-review: $oc not found" >&2; exit 2; }
  mkdir -p "$tmp/bin"; cp "$ocpath" "$tmp/bin/opencode"; chmod 755 "$tmp/bin" "$tmp/bin/opencode"
  # $tmp: traversable, not listable; only the diff and the binary are
  # readable by others; the review user's own folders are 700.
  chmod 711 "$tmp"; chmod 644 "$diff_abs"
  sudo -n chown -R "$review_user" "$tmp/src" "$tmp/home" "$tmp/xdg"
  sudo -n chmod 700 "$tmp/src" "$tmp/home" "$tmp/xdg"
  sudo -n -u "$review_user" test -r "$diff_abs" ||
    { echo "opencode-review: $review_user cannot read $tmp (a parent folder is closed?)" >&2; exit 2; }
  # src is 700 and the review user's: it changes there itself (GNU env -C).
  rundir="$tmp"
  launch=(sudo -n -u "$review_user" -- env -i -C "$tmp/src" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME"
    XDG_STATE_HOME="$XDG_STATE_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" "$tmp/bin/opencode")
else
  rundir="$tmp/src"
  launch=(${sandbox[@]+"${sandbox[@]}"} env -u OPENCODE_API_KEY "$oc")
fi

# Try the models in order; move on only on the free-quota error.
quota_hit=()
for model in "${models[@]}"; do
  (cd "$rundir" && "${launch[@]}" run --standalone --print-logs --log-level error --format json -m "$model" -f "$diff_abs" "$prompt" \
    </dev/null >"$tmp/run.jsonl" 2>"$tmp/run.err")
  rc=$?
  [ "$rc" = 0 ] && break
  # One awk over the whole file, no pipe: under pipefail a `grep | grep -q`
  # can end in SIGPIPE (141) on a long log and hide the quota error.
  if awk -v m="$quota_msg" '/level=ERROR/ && index($0, m) { f = 1 } END { exit !f }' "$tmp/run.err"; then
    echo "opencode-review: $model: free usage limit reached; trying the next model" >&2
    quota_hit+=("$model")
    continue
  fi
  echo "opencode-review: opencode exited $rc ($model)" >&2
  show_errors
  exit 1
done
if [ "$rc" != 0 ]; then
  echo "opencode-review: free usage limit reached on every model (${models[*]}); no review" >&2
  exit 4
fi

python3 - "$tmp/run.jsonl" "$tmp/body.md" <<'EOF' || exit 1
import base64, json, os, sys
texts, tokens = [], {"input": 0, "output": 0}
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    part = event.get("part") or {}
    kind = event.get("type")
    # The answer is every text part of the last model step: a new step drops
    # the narration of the earlier ones (between tool calls). Reasoning comes
    # as its own part type and is never posted.
    if kind == "step_start":
        texts = []
    elif kind == "text" and (part.get("text") or "").strip():
        texts.append(part["text"].strip())
    elif kind == "step_finish":
        for k in tokens:
            tokens[k] += (part.get("tokens") or {}).get(k) or 0
body = "\n\n".join(texts)
# Defence in depth: never post the key, whatever the agent managed to read
# (the key is kept out of opencode's reach, see the header).
key = os.environ.get("OPENCODE_API_KEY", "")
if len(key) >= 8:
    forms = {key, base64.b64encode(key.encode()).decode().rstrip("="),
             base64.urlsafe_b64encode(key.encode()).decode().rstrip("="), key.encode().hex()}
    body_l = body.lower()
    if any(f in body or f.lower() in body_l for f in forms):
        print("opencode-review: the review text contains OPENCODE_API_KEY; not written", file=sys.stderr)
        sys.exit(3)
open(sys.argv[2], "w", encoding="utf-8").write(body)
print(f"tokens in={tokens['input']} out={tokens['output']}", file=sys.stderr)
EOF
if [ ! -s "$tmp/body.md" ]; then
  echo "opencode-review: the model returned no text" >&2
  show_errors
  exit 1
fi

{
  printf '<!-- ai-review:opencode -->\n'
  printf '### AI review (opencode, `%s`)\n\n' "$model"
  printf '<sub>Reviewed head `%s`, %s.</sub>\n\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  [ -n "$note" ] && printf '> %s\n\n' "$note"
  [ "${#quota_hit[@]}" -gt 0 ] && printf '> Free usage limit reached on %s; reviewed by `%s` instead.\n\n' "$(printf '`%s` ' "${quota_hit[@]}" | sed 's/ $//')" "$model"
  head -c 60000 "$tmp/body.md"
  printf '\n\n<sub>Zero-retention free model via opencode Zen; read-only agent. Pilot, card 01-084: judge each finding as useful, wrong or noise.</sub>\n'
} >"$out"
