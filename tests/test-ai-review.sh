#!/usr/bin/env bash
# Tests for the PR review workflow (.github/workflows/ai-review.yml) and
# scripts/opencode-review.sh (card 01-084). No model is called: a fake
# opencode prints canned JSONL events.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
wf="$here/.github/workflows/ai-review.yml"
script="$here/scripts/opencode-review.sh"
probe=""
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; [ -n "$probe" ] && rm -rf "$probe"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -f "$tmp/out" ] && sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- the workflow, statically --------------------------------------------
check "workflow exists" '[ -f "$wf" ]'
check "never pull_request_target" '! grep -v "^ *#" "$wf" | grep -q pull_request_target'
check "triggers on pull_request" 'grep -q "^  pull_request:" "$wf"'
check "reviews every push (synchronize)" 'grep -q "types: \[opened, synchronize, reopened, ready_for_review\]" "$wf"'
check "top-level permissions are empty" 'grep -q "^permissions: {}" "$wf"'
check "job permissions minimal" 'grep -q "contents: read" "$wf" && grep -q "pull-requests: write" "$wf" && ! grep -Eq "(contents|issues|actions|id-token): write" "$wf"'
uses="$(grep -E '^\s*(- )?uses:' "$wf" | sed -E 's/.*uses: *//; s/ .*//')"
check "every action pinned to a full commit SHA" '[ -n "$uses" ] && ! printf "%s\n" "$uses" | grep -Ev "@[0-9a-f]{40}$"'
check "the key comes only from the secret" '[ "$(grep -c OPENCODE_API_KEY "$wf")" -ge 2 ] && ! grep -E "OPENCODE_API_KEY: [^$]" "$wf" | grep -v "secrets.OPENCODE_API_KEY" | grep -q .'
check "only GITHUB_TOKEN for GitHub" '! grep -Eq "secrets\.(GH_|PAT|GITHUB_PAT)" "$wf"'
check "missing secret skips with a notice" 'grep -q "HAS_KEY: \${{ secrets.OPENCODE_API_KEY != '"''"' }}" "$wf" && grep -q "::notice title=AI review skipped::" "$wf"'
check "every later step waits for the gate" '[ "$(grep -c "if: steps.gate.outputs.run == '"'true'"'" "$wf")" = 4 ]'
check "job timeout leaves room for a 10-15 min review" 'grep -Eq "^    timeout-minutes: (2[5-9]|[3-5][0-9])( |$)" "$wf"'
check "checkout keeps no credentials" 'grep -q "persist-credentials: false" "$wf"'
check "opencode download is verified" 'grep -q "sha256sum -c" "$wf"'
check "zero-retention models, in order (card 183)" 'grep -qx "      MODELS: opencode/deepseek-v4.1-flash-free opencode/glm-5.3-flash-free" "$wf" && grep -q "AI_REVIEW_MODELS: \${{ env.MODELS }}" "$wf"'
check "the model list goes by environment, not argv" 'grep -q "bash \"\$RUNNER_TEMP/opencode-review.sh\" \"\$RUNNER_TEMP/pr.diff\" \"\$RUNNER_TEMP/review.md\" || rc=\$?$" "$wf"'
check "no comment is posted when every model is out of quota" 'grep -q "if: steps.gate.outputs.run == '"'true'"' && steps.review.outputs.quota != '"'true'"'" "$wf"'
check "the key step runs the reviewer from the base commit" 'grep -q "git show \"\$BASE_SHA:scripts/opencode-review.sh\" >\"\$RUNNER_TEMP/opencode-review.sh\"" "$wf" && grep -q "bash \"\$RUNNER_TEMP/opencode-review.sh\"" "$wf"'
check "nothing runs from the PR head's scripts/" '! grep -v "^ *#" "$wf" | grep -Eq "(bash|sh|python3?) +\.?/?scripts/"'
check "the review runs opencode as a separate user (card 157)" 'grep -q "sudo useradd --system --no-create-home --shell /usr/sbin/nologin aireview" "$wf" && grep -q "AI_REVIEW_USER: aireview" "$wf"'
check "the key is in exactly one step's env" '[ "$(grep -c "OPENCODE_API_KEY: \${{ secrets.OPENCODE_API_KEY }}" "$wf")" = 1 ]'
check "diff runs without external drivers or textconv" 'grep -q "git diff --no-color --no-ext-diff --no-textconv" "$wf"'
if command -v ruby >/dev/null 2>&1; then
  check "workflow is valid YAML" 'ruby -ryaml -e "YAML.load_file(ARGV[0])" "$wf" >"$tmp/out" 2>&1'
fi

# --- the gate step, run as bash ------------------------------------------
gate="$(awk '/- name: Decide whether to review/{f=1} f&&/run: \|/{g=1;next} g&&/^      - name:/{exit} g' "$wf" | sed 's/^          //')"
run_gate() { # HAS_KEY IS_DRAFT HEAD_REPO
  : >"$tmp/gh_out"; : >"$tmp/gh_sum"
  HAS_KEY="$1" IS_DRAFT="$2" HEAD_REPO="$3" GITHUB_REPOSITORY=sbartek/x \
    GITHUB_OUTPUT="$tmp/gh_out" GITHUB_STEP_SUMMARY="$tmp/gh_sum" bash -c "$gate" >"$tmp/out" 2>&1
}
run_gate false false sbartek/x
check "no key: gate exits 0, run=false, notice" '[ $? = 0 ] && grep -q "run=false" "$tmp/gh_out" && grep -q "::notice title=AI review skipped::repository secret OPENCODE_API_KEY is not set" "$tmp/out"'
run_gate true true sbartek/x
check "draft: skipped" 'grep -q "run=false" "$tmp/gh_out" && grep -q "draft PR" "$tmp/out"'
run_gate true false someone/x
check "fork: skipped" 'grep -q "run=false" "$tmp/gh_out" && grep -q "fork" "$tmp/out"'
run_gate true false sbartek/x
check "key, same repo: run=true" 'grep -q "run=true" "$tmp/gh_out"'

# --- the diff lines of the review step, run in a repo ----------------------
dlines="$(grep -E "^ *(echo '\* !diff'|git diff --no-color)" "$wf" | sed 's/^ *//')"
d="$tmp/drepo"; mkdir -p "$d"; git -C "$d" init -q
echo base >"$d/notes.md"; git -C "$d" add -A; git -C "$d" commit -q -m base
base_sha="$(git -C "$d" rev-parse HEAD)"
echo 'notes.md -diff' >"$d/.gitattributes"; echo 'secret change' >>"$d/notes.md"
printf 'PNG\0\1\2\3' >"$d/img.bin"; git -C "$d" add -A; git -C "$d" commit -q -m pr
(cd "$d" && BASE_SHA="$base_sha" HEAD_SHA="$(git rev-parse HEAD)" RUNNER_TEMP="$tmp" bash -e -c "$dlines") >"$tmp/out" 2>&1
check "diff: a PR's -diff attribute cannot hide a text change" '[ $? = 0 ] && grep -q "^+secret change" "$tmp/pr.diff"'
check "diff: a real binary stays one 'Binary files differ' line" 'grep -q "^Binary files /dev/null and b/img.bin differ" "$tmp/pr.diff"'
check "diff: the checkout's tracked files are untouched" '[ -z "$(git -C "$d" status --porcelain)" ]'

# --- the end of the review step: exit 4 (all out of quota) skips green ------
rtail="$(awk '/^ *rc=0$/{f=1} f{print} f&&/^ *exit "\$rc"$/{exit}' "$wf" | sed 's/^          //')"
run_rtail() { # exit code of the fake reviewer
  mkdir -p "$tmp/rv"; : >"$tmp/gh_out"; : >"$tmp/gh_sum"
  printf 'exit %s\n' "$1" >"$tmp/rv/opencode-review.sh"
  RUNNER_TEMP="$tmp/rv" AI_REVIEW_MODELS="m1 m2" GITHUB_OUTPUT="$tmp/gh_out" GITHUB_STEP_SUMMARY="$tmp/gh_sum" \
    bash -e -c "$rtail" >"$tmp/out" 2>&1
}
run_rtail 4
check "review step: every model out of quota -> green, notice, quota=true" '[ $? = 0 ] && grep -q "::notice title=AI review skipped::free usage limit reached on every model (m1 m2)" "$tmp/out" && grep -qx "quota=true" "$tmp/gh_out"'
run_rtail 1
check "review step: any other failure stays red" '[ $? = 1 ] && ! grep -q quota "$tmp/gh_out"'
run_rtail 0
check "review step: a review -> green, comment not skipped" '[ $? = 0 ] && ! grep -q quota "$tmp/gh_out"'

# --- the comment step, run as bash with a fake gh -------------------------
post="$(awk '/- name: Post the review comment/{f=1} f&&/run: \|/{g=1;next} g' "$wf" | sed 's/^          //')"
mkdir -p "$tmp/ghbin"
cat >"$tmp/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: comments from $FAKE_COMMENTS; log every call (and stdin) to $GH_LOG
printf 'gh %s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "api repos/sbartek/x/issues/7/comments")
    q=""; while [ $# -gt 0 ]; do [ "$1" = --jq ] && q="$2"; shift; done
    jq -r "$q" "$FAKE_COMMENTS" ;;
  "api -X") if [ "$3" = PATCH ]; then cat >>"$GH_LOG"; fi ;;
  "pr comment") echo "new comment" ;;
esac
EOF
chmod +x "$tmp/ghbin/gh"
printf '<!-- ai-review:opencode -->\n### AI review\nnew text\n' >"$tmp/rt_review.md"
run_post() { # comments.json
  : >"$tmp/gh_log"; mkdir -p "$tmp/rt"; cp "$tmp/rt_review.md" "$tmp/rt/review.md"
  PATH="$tmp/ghbin:$PATH" GH_LOG="$tmp/gh_log" FAKE_COMMENTS="$1" PR=7 GITHUB_REPOSITORY=sbartek/x \
    RUNNER_TEMP="$tmp/rt" bash -e -o pipefail -c "$post" >"$tmp/out" 2>&1
}
echo '[{"id":1,"user":{"login":"sbartek"},"body":"<!-- ai-review:opencode --> fake"},{"id":2,"user":{"login":"github-actions[bot]"},"body":"other bot note"}]' >"$tmp/c1.json"
run_post "$tmp/c1.json"
check "comment step: no earlier review -> posts a new comment" '[ $? = 0 ] && grep -q "^gh pr comment 7 --repo sbartek/x --body-file" "$tmp/gh_log" && ! grep -q PATCH "$tmp/gh_log"'
echo '[{"id":5,"user":{"login":"github-actions[bot]"},"body":"### AI review (opencode, `m`) old"},{"id":9,"user":{"login":"github-actions[bot]"},"body":"<!-- ai-review:opencode -->\nolder"}]' >"$tmp/c2.json"
run_post "$tmp/c2.json"
check "comment step: earlier reviews -> updates the newest, deletes the older, no new comment" '[ $? = 0 ] && grep -q "^gh api -X PATCH repos/sbartek/x/issues/comments/9 --input -" "$tmp/gh_log" && grep -q "new text" "$tmp/gh_log" && grep -qx "gh api -X DELETE repos/sbartek/x/issues/comments/5" "$tmp/gh_log" && [ "$(grep -c DELETE "$tmp/gh_log")" = 1 ] && ! grep -q "pr comment" "$tmp/gh_log"'
echo '[{"id":9,"user":{"login":"github-actions[bot]"},"body":"<!-- ai-review:opencode -->\nolder"}]' >"$tmp/c3.json"
run_post "$tmp/c3.json"
check "comment step: one earlier review -> updated, nothing deleted" '[ $? = 0 ] && grep -q "PATCH repos/sbartek/x/issues/comments/9" "$tmp/gh_log" && ! grep -q DELETE "$tmp/gh_log"'

# --- the review script with a fake opencode -------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
# fake: record args and cwd, print canned events
printf '%s\n' "$PWD" >"$FAKE_LOG"; printf '%s\n' "$@" >>"$FAKE_LOG"
printf 'HOME=%s\nXDG_CONFIG_HOME=%s\n' "$HOME" "$XDG_CONFIG_HOME" >"$FAKE_LOG.env"
cp a.sh "$FAKE_LOG.a.sh" 2>/dev/null
[ -n "${FAKE_FAIL:-}" ] && { echo "boom" >&2; exit 3; }
echo '{"type":"step_start","part":{}}'
echo '{"type":"text","part":{"type":"text","text":"thinking out loud"}}'
echo '{"type":"tool_use","part":{"state":{"status":"completed"}}}'
echo '{"type":"step_finish","part":{"tokens":{"input":10,"output":5}}}'
echo '{"type":"step_start","part":{}}'
echo '{"type":"reasoning","part":{"type":"reasoning","text":"private reasoning"}}'
echo '{"type":"text","part":{"type":"text","text":"1. `a.sh:2` bug: wrong sign."}}'
echo '{"type":"text","part":{"type":"text","text":"2. `b.sh:1` nit: typo."}}'
echo '{"type":"step_finish","part":{"tokens":{"input":10,"output":5}}}'
EOF
chmod +x "$tmp/bin/opencode"
r="$tmp/repo"; mkdir -p "$r"; git -C "$r" init -q
echo 'echo hi' >"$r/a.sh"; echo '{"permissions":[]}' >"$r/opencode.json"
mkdir -p "$r/sub"; echo x >"$r/sub/hidden.md"
printf 'sub/hidden.md export-ignore\n*.md -diff\na.sh filter=evil\n' >"$r/.gitattributes"
ln -s /etc/hosts "$r/leak"
git -C "$r" add -A; git -C "$r" commit -q -m one
echo 'echo bye' >>"$r/a.sh"; git -C "$r" commit -qam two
git -C "$r" diff HEAD~1 HEAD >"$tmp/pr.diff"
# a smudge filter configured on the machine must never run for the copy
git -C "$r" config filter.evil.smudge "touch '$tmp/smudged'; cat"
review() { (cd "$r" && OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$@") >"$tmp/out" 2>&1; }

review "$tmp/pr.diff" "$tmp/review.md"
check "review: exit 0; every text of the last step is posted, earlier narration and reasoning not" '[ $? = 0 ] && grep -q "a.sh:2. bug: wrong sign" "$tmp/review.md" && grep -q "b.sh:1. nit: typo" "$tmp/review.md" && ! grep -q "thinking out loud" "$tmp/review.md" && ! grep -q "private reasoning" "$tmp/review.md"'
check "review: comment starts with the marker the workflow updates by" '[ "$(head -1 "$tmp/review.md")" = "<!-- ai-review:opencode -->" ]'
check "review: opencode gets a throwaway HOME and XDG config, not the real ones" '! grep -qx "HOME=$HOME" "$tmp/log.env" && grep -q "^XDG_CONFIG_HOME=/.*/xdg/config$" "$tmp/log.env"'
check "review: the copy ran no smudge filter and kept the blob bytes (no attributes applied)" '[ ! -e "$tmp/smudged" ] && [ "$(cat "$tmp/log.a.sh" 2>/dev/null)" = "$(git -C "$r" show HEAD:a.sh)" ]'
check "review: comment names the reviewed head" 'grep -q "Reviewed head .$(git -C "$r" rev-parse --short HEAD)." "$tmp/review.md"'
check "review: header names the first model of the default list" 'grep -q "AI review (opencode, .opencode/deepseek-v4.1-flash-free.)" "$tmp/review.md"'
check "review: runs headless with the model and the diff" 'grep -qx -- "--standalone" "$tmp/log" && grep -qx "opencode/deepseek-v4.1-flash-free" "$tmp/log" && grep -qx -- "-f" "$tmp/log"'
check "review: agent runs in a copy, not the checkout" '[ "$(head -1 "$tmp/log")" != "$r" ] && [ "$(cd "$r" && pwd -P)" != "$(head -1 "$tmp/log")" ]'
check "review: checkout untouched (its opencode.json kept, no jsonc added)" '[ -f "$r/opencode.json" ] && [ ! -f "$r/opencode.jsonc" ] && [ -z "$(git -C "$r" status --porcelain)" ]'
review "$tmp/pr.diff" "$tmp/review.md" opencode/glm-5.3-flash-free
check "review: model argument wins" 'grep -qx "opencode/glm-5.3-flash-free" "$tmp/log"'
for m in opencode/big-pickle opencode/minimax-m3-free deepseek-v4.1-flash-free opencode/longcat-2.5-preview-free \
    "opencode/glm-5.3-flash-free opencode/big-pickle"; do
  rm -f "$tmp/log"
  review "$tmp/pr.diff" "$tmp/review.md" "$m"
  check "review: model $m refused (exit 2, opencode never called)" '[ $? = 2 ] && grep -q "not a zero-retention free model" "$tmp/out" && [ ! -f "$tmp/log" ]'
done
rm -f "$tmp/log"
(cd "$r" && AI_REVIEW_MODEL=opencode/big-pickle OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
check "review: a bad AI_REVIEW_MODEL is refused too" '[ $? = 2 ] && [ ! -f "$tmp/log" ]'
(cd "$r" && AI_REVIEW_MODELS="opencode/glm-5.3-flash-free,opencode/flint-40b-free" OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
check "review: a bad model anywhere in AI_REVIEW_MODELS is refused before any call" '[ $? = 2 ] && grep -q "flint-40b-free is not" "$tmp/out" && [ ! -f "$tmp/log" ]'

# --- the model list (card 183): fall back only on the free-quota error -------
# The fake fails with Zen's quota error (as opencode 2.1.3 logged it in the
# PR #13/#14 runs) for the models in $FAKE_QUOTA, with another error for
# those in $FAKE_OTHER, and reviews otherwise; it logs every model it got.
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
m=""; while [ $# -gt 0 ]; do [ "$1" = -m ] && m="$2"; shift; done
echo "$m" >>"$FAKE_LOG.models"
case " ${FAKE_QUOTA:-} " in *" $m "*)
  echo 'timestamp=2026-10-27T06:57:15.688Z level=ERROR run=47a84d54 message="Failed to drain Session" cause="AI.Error: Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go\n    at JQ (/$bunfs/root/chunk-6vj5szb8.js:3:3504)"' >&2
  exit 1 ;;
esac
case " ${FAKE_OTHER:-} " in *" $m "*)
  echo 'timestamp=2026-10-27T06:57:15.688Z level=ERROR message="Failed to drain Session" cause="AI.Error: Internal server error"' >&2
  exit 1 ;;
esac
printf '{"type":"text","part":{"text":"review by %s"}}\n' "$m"
EOF
chmod +x "$tmp/bin/opencode"
list() { # env assignments...
  rm -f "$tmp/log.models" "$tmp/review.md"
  (cd "$r" && env "$@" OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
}
DS=opencode/deepseek-v4.1-flash-free GLM=opencode/glm-5.3-flash-free
list AI_REVIEW_MODELS="$DS $GLM"
check "models: the first works -> only it is called, the comment names it" '[ $? = 0 ] && [ "$(cat "$tmp/log.models")" = "$DS" ] && grep -q "AI review (opencode, .$DS.)" "$tmp/review.md" && grep -q "review by $DS" "$tmp/review.md" && ! grep -q "Free usage limit" "$tmp/review.md"'
list AI_REVIEW_MODELS="$DS $GLM" FAKE_QUOTA="$DS"
check "models: the first out of quota, the second works -> the comment names the second and says why" '[ $? = 0 ] && [ "$(tr "\n" " " <"$tmp/log.models")" = "$DS $GLM " ] && grep -q "AI review (opencode, .$GLM.)" "$tmp/review.md" && grep -q "review by $GLM" "$tmp/review.md" && grep -q "Free usage limit reached on .$DS.; reviewed by .$GLM. instead" "$tmp/review.md"'
list AI_REVIEW_MODELS="$DS,$GLM" FAKE_QUOTA="$DS $GLM"
check "models: all out of quota -> exit 4, both tried, nothing written" '[ $? = 4 ] && [ "$(wc -l <"$tmp/log.models" | tr -d " ")" = 2 ] && [ ! -f "$tmp/review.md" ] && grep -q "free usage limit reached on every model" "$tmp/out"'
list AI_REVIEW_MODELS="$DS $GLM" FAKE_OTHER="$DS"
check "models: a non-quota error is not retried -> exit 1, second never called" '[ $? = 1 ] && [ "$(cat "$tmp/log.models")" = "$DS" ] && [ ! -f "$tmp/review.md" ] && grep -q "Internal server error" "$tmp/out"'
# A long log with the quota line first: a `grep | grep -q` pipeline under
# pipefail would end in SIGPIPE (141) and miss the quota (card 184 review).
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
m=""; while [ $# -gt 0 ]; do [ "$1" = -m ] && m="$2"; shift; done
echo "$m" >>"$FAKE_LOG.models"
if [ "$m" = opencode/deepseek-v4.1-flash-free ]; then
  echo 'timestamp=2026-10-27T06:57:15.688Z level=ERROR run=1 message="Failed to drain Session" cause="AI.Error: Free usage limit reached. Free models work in OpenCode"' >&2
  python3 -c 'import sys
line = "timestamp=2026-10-27T06:57:15.700Z level=ERROR run=1 message=\"noise\" " + "x" * 200 + "\n"
sys.stderr.write(line * 20000)'
  exit 1
fi
printf '{"type":"text","part":{"text":"review by %s"}}\n' "$m"
EOF
list AI_REVIEW_MODELS="$DS $GLM"
check "models: quota line early in a long ERROR log (SIGPIPE-prone) still falls back" '[ $? = 0 ] && [ "$(tr "\n" " " <"$tmp/log.models")" = "$DS $GLM " ] && grep -q "review by $GLM" "$tmp/review.md"'
# back to the configurable fake
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
m=""; while [ $# -gt 0 ]; do [ "$1" = -m ] && m="$2"; shift; done
echo "$m" >>"$FAKE_LOG.models"
case " ${FAKE_QUOTA:-} " in *" $m "*)
  echo 'timestamp=2026-10-27T06:57:15.688Z level=ERROR message="Failed to drain Session" cause="AI.Error: Free usage limit reached."' >&2
  exit 1 ;;
esac
printf '{"type":"text","part":{"text":"review by %s"}}\n' "$m"
EOF
list
check "models: the default list is deepseek then glm" '[ $? = 0 ] && [ "$(cat "$tmp/log.models")" = "$DS" ]'
list FAKE_QUOTA="$DS"
check "models: ...and the default falls back to glm" '[ $? = 0 ] && [ "$(tr "\n" " " <"$tmp/log.models")" = "$DS $GLM " ]'

# the config the agent sees: deny all, then read/glob/grep
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
cp opencode.jsonc "$FAKE_LOG.cfg"; ls -a >"$FAKE_LOG.ls"; find . >"$FAKE_LOG.find"
cat "$FAKE_SECRET" >"$FAKE_LOG.secret" 2>/dev/null
echo '{"type":"text","part":{"text":"No issues found."}}'
EOF
mkdir -p "$tmp/realhome"; echo "SECRET-$$" >"$tmp/realhome/secret.txt"
review "$tmp/pr.diff" "$tmp/review.md"
check "review: the copy's config denies everything but read/glob/grep, and external directories" 'python3 -c "
import json,sys; p=json.load(open(sys.argv[1]))[\"permissions\"]
assert p[0]==dict(action=\"*\",resource=\"*\",effect=\"deny\"), p
assert sorted(r[\"action\"] for r in p if r[\"effect\"]==\"allow\")==[\"glob\",\"grep\",\"read\"], p
assert dict(action=\"external_directory\",resource=\"*\",effect=\"deny\") in p, p" "$tmp/log.cfg"'
check "review: the PR's own opencode.json is dropped from the copy" '! grep -qx opencode.json "$tmp/log.ls" && grep -qx a.sh "$tmp/log.ls"'
check "review: export-ignore cannot hide a file from the copy" 'grep -qx "./sub/hidden.md" "$tmp/log.find"'
check "review: symlinks are removed from the copy" '! grep -qx "./leak" "$tmp/log.find"'
if command -v sandbox-exec >/dev/null 2>&1; then
  (cd "$r" && HOME="$tmp/realhome" FAKE_SECRET="$tmp/realhome/secret.txt" OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
  check "review (macOS): the OS sandbox denies the real HOME" '[ $? = 0 ] && [ -f "$tmp/log.ls" ] && ! grep -q "SECRET-" "$tmp/log.secret" 2>/dev/null'
  (cd "$r" && HOME="$tmp/elsewhere" FAKE_SECRET="$tmp/realhome/secret.txt" OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
  check "review (macOS): ...and only HOME (control: readable when HOME is elsewhere)" 'grep -q "SECRET-" "$tmp/log.secret"'
  mkdir -p "$tmp/realhome/.opencode/bin"; cp "$tmp/bin/opencode" "$tmp/realhome/.opencode/bin/opencode"; rm -f "$tmp/log.ls" "$tmp/log.secret"
  (cd "$r" && HOME="$tmp/realhome" FAKE_SECRET="$tmp/realhome/secret.txt" OPENCODE_BIN="$tmp/realhome/.opencode/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
  check "review (macOS): an opencode installed in HOME still runs, HOME still denied" '[ $? = 0 ] && [ -f "$tmp/log.ls" ] && ! grep -q "SECRET-" "$tmp/log.secret" 2>/dev/null'
fi

: >"$tmp/empty.diff"
review "$tmp/empty.diff" "$tmp/review.md"
check "empty diff: exit 0, says nothing to review, with the marker" '[ $? = 0 ] && grep -q "nothing to review" "$tmp/review.md" && [ "$(head -1 "$tmp/review.md")" = "<!-- ai-review:opencode -->" ]'

printf 'x%.0s' $(seq 1 300) >"$tmp/big.diff"
(cd "$r" && AI_REVIEW_MAX_DIFF_BYTES=100 OPENCODE_BIN="$tmp/bin/opencode" FAKE_LOG="$tmp/log" bash "$script" "$tmp/big.diff" "$tmp/review.md") >"$tmp/out" 2>&1
check "big diff: cut and said so" 'grep -q "cut to its first 100 bytes" "$tmp/review.md"'

cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo boom >&2; exit 3
EOF
review "$tmp/pr.diff" "$tmp/review.md"
check "opencode failure: exit 1" '[ $? = 1 ] && grep -q "exited 3" "$tmp/out"'
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"step_start","part":{}}'
EOF
review "$tmp/pr.diff" "$tmp/review.md"
check "no text from the model: exit 1" '[ $? = 1 ] && grep -q "no text" "$tmp/out"'
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"step_start","part":{}}'
echo '{"type":"text","part":{"text":"  \n "}}'
echo '{"type":"text","part":{"text":"\t"}}'
EOF
review "$tmp/pr.diff" "$tmp/review.md"
check "whitespace-only text from the model: exit 1" '[ $? = 1 ] && grep -q "no text" "$tmp/out"'
# the key never reaches the comment, in any of the encodings the guard knows
# (a leak is simulated: since card 01-157 opencode never has the key)
fake_key="fakekey-$$-$RANDOM-$RANDOM"   # built at run time: no key-like literal in git
printf %s "$fake_key" >"$tmp/leaked"
cat >"$tmp/bin/opencode" <<EOF
#!/usr/bin/env bash
v="\$(cat "$tmp/leaked")"
case "\${FAKE_ENC:-}" in
  b64) v="\$(printf %s "\$v" | base64)" ;;
  hex) v="\$(printf %s "\$v" | od -An -tx1 | tr -d ' \n' | tr a-f A-F)" ;;
esac
printf '{"type":"text","part":{"text":"leak: %s"}}\n' "\$v"
EOF
for enc in "" b64 hex; do
  rm -f "$tmp/review.md"
  (cd "$r" && OPENCODE_API_KEY="$fake_key" FAKE_ENC="$enc" AI_REVIEW_UPSTREAM=http://127.0.0.1:9 OPENCODE_BIN="$tmp/bin/opencode" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
  check "key in the model's text (${enc:-plain}): exit 1, nothing written" '[ $? = 1 ] && [ ! -f "$tmp/review.md" ] && grep -q "contains OPENCODE_API_KEY" "$tmp/out" && ! grep -qF "$fake_key" "$tmp/out"'
done

# --- key isolation (card 01-157) --------------------------------------------
# A fake upstream records what reaches it; a fake opencode looks for the key
# everywhere it can and calls the proxy it was configured with.
cat >"$tmp/upstream.py" <<'EOF'
import http.server, sys
class U(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(sys.argv[2], "a") as fh:
            fh.write("%s %s %s\n" % (self.command, self.path, self.headers.get("authorization")))
        body = b"data: hello-from-upstream\n\n"
        self.send_response(200); self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), U)
open(sys.argv[1], "w").write(str(s.server_address[1])); s.serve_forever()
EOF
python3 -I "$tmp/upstream.py" "$tmp/up.port" "$tmp/up.log" & up_pid=$!
for _ in $(seq 1 50); do [ -s "$tmp/up.port" ] && break; sleep 0.1; done
# The probe may write here (sticky, not listable); removed by the EXIT trap.
probe="$(mktemp -d /tmp/aireview-probe.XXXXXX)"; chmod 1733 "$probe"
echo "runner-only" >"$tmp/runner-secret"; chmod 600 "$tmp/runner-secret"
cat >"$tmp/bin/opencode" <<EOF
#!/usr/bin/env bash
# fake opencode: dump every environment it can read, try a caller-only file,
# then call the configured provider through the proxy.
out="$probe/dump"
env >"\$out.ownenv"
{ env; for f in /proc/[0-9]*/environ; do tr '\0' '\n' <"\$f" 2>/dev/null; done; } >"\$out.env"
ps eww -A >>"\$out.env" 2>/dev/null
id -u >"\$out.uid"
cat "$tmp/runner-secret" >"\$out.secret" 2>/dev/null
cp opencode.jsonc "\$out.cfg"
base="\$(python3 -c 'import json,re,sys; t=open("opencode.jsonc").read(); print(json.loads(t)["provider"]["opencode"]["options"]["baseURL"])')"
tok="\$(python3 -c 'import json,sys; print(json.load(open("opencode.jsonc"))["provider"]["opencode"]["options"]["apiKey"])')"
ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ' >"\$out.nproc"
curl -sS -X POST -H "Authorization: Bearer \$tok" -H "Content-Type: application/json" -d '{"x":1}' "\$base/chat/completions" >"\$out.resp" 2>&1
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer \$tok" "\${base%/zen/v1}/other" >"\$out.other" 2>&1
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer \$tok" "\$base/%2e%2e/%2e%2e/other" >"\$out.dots" 2>&1
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer wrong" "\$base/chat/completions" >"\$out.wrongtok" 2>&1
printf '{"type":"text","part":{"text":"probe done"}}\n'
EOF
chmod 755 "$tmp/bin/opencode"
iso_run() { # extra env assignments...
  rm -f "$probe"/dump.*; : >"$tmp/up.log"
  (cd "$r" && env "$@" OPENCODE_API_KEY="$fake_key" AI_REVIEW_UPSTREAM="http://127.0.0.1:$(cat "$tmp/up.port")" \
    OPENCODE_BIN="$tmp/bin/opencode" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
}
iso_checks() { # label
  check "$1: review written" '[ $? = 0 ] && grep -q "probe done" "$tmp/review.md"'
  check "$1: the probe ran and read environments" '[ -s "$probe/dump.env" ] && grep -q "^PATH=" "$probe/dump.env"'
  check "$1: the key is not in opencode's own environment" '[ -s "$probe/dump.ownenv" ] && ! grep -qF "$fake_key" "$probe/dump.ownenv"'
  check "$1: the key is not in opencode's config" '[ -s "$probe/dump.cfg" ] && ! grep -qF "$fake_key" "$probe/dump.cfg" && grep -q "\"baseURL\": \"http://127.0.0.1:[0-9]*/zen/v1\"" "$probe/dump.cfg"'
  check "$1: the proxy adds the real key upstream and streams the answer back" 'grep -qx "POST /zen/v1/chat/completions Bearer $fake_key" "$tmp/up.log" && grep -q "hello-from-upstream" "$probe/dump.resp"'
  check "$1: the proxy forwards nothing outside /zen/, also not through %2e%2e" '[ "$(cat "$probe/dump.other")" = 403 ] && [ "$(cat "$probe/dump.dots")" = 403 ] && [ "$(wc -l <"$tmp/up.log")" -eq 1 ]'
  check "$1: the proxy refuses a caller without the run's token" '[ "$(cat "$probe/dump.wrongtok")" = 401 ]'
  check "$1: the run's token is not the key" '! grep -qF "$fake_key" "$probe/dump.cfg"'
}
proxies() { pgrep -f "python3 -I .*/proxy.py .*/proxy.port" | wc -l | tr -d ' '; }
before="$(proxies)"
iso_run
iso_checks "isolation"
check "isolation: the proxy is gone after the run" '[ "$(proxies)" = "$before" ] && ! grep -q "proxy.py" "$tmp/out"'
# Linux CI: opencode runs as another user (AI_REVIEW_USER), like the workflow.
if [ "$(uname -s)" = Linux ] && [ "${CI:-}" = true ] && sudo -n true 2>/dev/null; then
  check "control: run as the same user, the probe does find the key (/proc of the caller)" 'grep -qF "$fake_key" "$probe/dump.env"'
  id -u aireview-test >/dev/null 2>&1 || sudo -n useradd --system --no-create-home --shell /usr/sbin/nologin aireview-test
  iso_run AI_REVIEW_USER=aireview-test
  iso_checks "isolation (other user)"
  check "isolation (other user): the key is in no environment opencode can read (/proc/*/environ, ps)" '! grep -qF "$fake_key" "$probe/dump.env"'
  check "isolation (other user): opencode ran as that user" '[ "$(cat "$probe/dump.uid")" = "$(id -u aireview-test)" ]'
  check "isolation (other user): it cannot read the caller's private files" '[ ! -s "$probe/dump.secret" ]'
  check "isolation (other user): the probe itself saw other processes in /proc" '[ "$(cat "$probe/dump.nproc")" -gt 1 ]'
  AI_REVIEW_USER="$(id -un)" bash -c 'cd "$1" && bash "$2" "$3" "$4"' _ "$r" "$script" "$tmp/pr.diff" "$tmp/review.md" >"$tmp/out" 2>&1
  check "AI_REVIEW_USER must be another user: exit 2" '[ $? = 2 ] && grep -q "another, non-root user" "$tmp/out"'
  sudo -n chown -R "$(id -u)" "$probe"
else
  echo "skip isolation as another user (Linux CI only)"
fi
kill "$up_pid" 2>/dev/null; wait "$up_pid" 2>/dev/null
rm -rf "$probe"
(cd "$tmp" && OPENCODE_BIN="$tmp/bin/opencode" bash "$script" "$tmp/pr.diff" "$tmp/review.md") >"$tmp/out" 2>&1
check "outside a git checkout: exit 2" '[ $? = 2 ]'

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
