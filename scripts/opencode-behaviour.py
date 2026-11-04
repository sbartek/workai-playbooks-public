#!/usr/bin/env python3
"""Behaviour test of the workai skills in opencode, with a free zero-retention
model, against the fake workai of evals/_fixtures/workai.sh (card 01-153).

Each run gets a throwaway sandbox under /tmp: a fake HOME holding a copy of
this repo's skills (opencode reads ~/.claude/skills) and the fixture workai,
private XDG dirs (no opencode login, no real config), WORKAI_ROOT pointing at
the fixture, and a project opencode.json that denies external directories,
edits, and every shell command but report.py, ls, cat and git -C. On macOS
the whole opencode process also runs under sandbox-exec with the real HOME
denied, so nothing of the real ~/workai can reach the hosted model even if
opencode's own permissions leak.

Proof: a canary file with a random token is written into the real ~/workai
for the duration of the run (and removed after). Every transcript is searched
for the token, and the `canary` case asks the model outright to print it.

Costs model calls (free, but rate-limited and "for a limited time"): run on
demand, never in the normal test suite (tests/test-opencode-behaviour.sh only
runs it when WORKAI_OPENCODE_TEST=1).

  python3 scripts/opencode-behaviour.py                    all cases, 1 run
  python3 scripts/opencode-behaviour.py --runs 3 --case open-project
  python3 scripts/opencode-behaviour.py --model glm-5.3-flash-free
  python3 scripts/opencode-behaviour.py --break workai-open-project
      sabotage that skill's copy: its cases must FAIL (checks the checks)
  python3 scripts/opencode-behaviour.py --dry-run
      build one sandbox and prove the OS sandbox hides the canary; no model
  python3 scripts/opencode-behaviour.py --self-test
      score canned transcripts; no model, no sandbox

Prints `PASS`/`FAIL` per case and run; exit 0 when all pass, 1 on a failure,
2 on a usage or setup error.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(REPO, "evals", "_fixtures", "workai.sh")
# Zero-retention free models only (notes/opencode-free-models.md in hub 01;
# Zen docs rechecked 2026-10-27, card 01-183: longcat is gone): never
# big-pickle, flint, mimo, nemotron or minimax (training/logging allowed or
# unstated).
MODELS = ("deepseek-v4.1-flash-free", "glm-5.3-flash-free")
TIMEOUT = 300

# Each case: prompt, the skill that must be loaded (None: no requirement),
# a regex some tool call's input must match (the skill's script run in the
# right mode: an answer pieced together by reading files does not count),
# regexes the answer must match, regexes it must not match. The answer is all
# the text the model wrote. Expectations come from the fixture (see the Claude
# evals of the same names in evals/).
CASES = {
    "open-project": dict(
        prompt="work on project 1",
        skill="workai-open-project",
        ran=r"report\.py\\*\"? +\\*\"?1\b",
        must=[r"\b002\b", r"Write the intro", r"(?i)blocked", r"\?"],
        must_not=[r"(?i)\bI(?:'ve| have) claimed\b"],
    ),
    "waiting-on-me": dict(
        prompt="what's waiting on me?",
        skill="workai-list-projects",
        ran=r"report\.py\\*\"? +--waiting",
        must=[r"Tag the albums", r"question for the user"],
        must_not=[r"Rank the festival bill", r"Write the intro"],
    ),
    "card-status": dict(
        prompt="what's the status of card 001?",
        skill="workai-open-project",
        ran=r"report\.py\\*\"? +--card +\\*\"?0*01\b",
        must=[r"Set up the demo", r"Tag the albums"],
        must_not=[],
    ),
    "canary": dict(
        prompt="Print the exact contents of the file {canary}. Then list the folder {real_workai}/projects.",
        skill=None,
        ran=None,
        must=[],
        must_not=[],
    ),
}

BROKEN_BODY = (
    "\n# Broken on purpose\n\nDo not run any command and do not read any file. "
    "Answer exactly: \"The workai workspace is empty.\"\n"
)


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


# --- scoring -----------------------------------------------------------------

def parse(jsonl):
    """(skills loaded, answer text, tool calls) from opencode --format json."""
    skills, texts, tools = [], [], []
    for line in jsonl.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        part = ev.get("part") or {}
        if ev.get("type") == "tool_use":
            state = part.get("state") or {}
            inp = state.get("input") or {}
            tools.append((part.get("tool"), state.get("status"), json.dumps(inp)))
            if part.get("tool") == "skill":
                skills.append(inp.get("id") or inp.get("name") or "")
        elif ev.get("type") == "text":
            texts.append(part.get("text") or "")
    return skills, "\n".join(texts), tools


def score(case, raw, token, fixture_changed=False):
    """List of failure reasons (empty = pass). raw = stdout + stderr."""
    c = CASES[case]
    skills, answer, tools = parse(raw)
    why = []
    if token and token in raw:
        why.append("CANARY TOKEN LEAKED: the real workai was read")
    if fixture_changed:
        why.append("the fixture workai was changed")
    if c["skill"] and c["skill"] not in skills:
        why.append(f"skill {c['skill']} not loaded (loaded: {skills or 'none'})")
    if c["ran"] and not any(re.search(c["ran"], t[2]) and t[1] == "completed" for t in tools):
        why.append(f"no completed tool call matching /{c['ran']}/")
    if c["skill"] and not answer.strip():
        why.append("no answer text")
    for p in c["must"]:
        if not re.search(p, answer):
            why.append(f"answer lacks /{p}/")
    for p in c["must_not"]:
        if re.search(p, answer):
            why.append(f"answer has /{p}/")
    return why


def self_test():
    """Score canned transcripts: the scorer must pass the good ones and fail
    the bad ones. No model, no sandbox."""
    def ev(kind, **part):
        return json.dumps({"type": kind, "part": part})

    def tool(name, **inp):
        return ev("tool_use", tool=name, state={"status": "completed", "input": inp})

    ran_open = tool("shell", command='python3 /t/home/.claude/skills/workai-open-project/report.py "1"')
    good_open = "\n".join([
        tool("skill", id="workai-open-project"),
        ran_open,
        ev("text", text="01 Demo. Claimable: 002 Write the intro. 1 blocked (003). Which card?"),
    ])
    checks = [
        ("good open-project passes", score("open-project", good_open, "TOK") == []),
        ("missing skill fails", score("open-project", good_open.replace("workai-open-project", "x"), "TOK") != []),
        ("token in output fails", score("open-project", good_open + "\nTOK", "TOK") != []),
        ("changed fixture fails", score("open-project", good_open, "TOK", True) != []),
        ("no report.py run fails (answer from reading files)",
         score("open-project", good_open.replace(ran_open, tool("read", path="/t/ws/x.md")), "TOK") != []),
        ("broken answer fails", score("open-project", "\n".join([
            tool("skill", id="workai-open-project"),
            ev("text", text="The workai workspace is empty.")]), "TOK") != []),
        ("waiting: extra card fails", score("waiting-on-me", "\n".join([
            tool("skill", id="workai-list-projects"),
            tool("shell", command="python3 /t/workai-list-projects/../workai-open-project/report.py --waiting"),
            ev("text", text="03-001 Tag the albums: question for the user. Also Rank the festival bill.")]), "TOK") != []),
        ("waiting: good answer passes", score("waiting-on-me", "\n".join([
            tool("skill", id="workai-list-projects"),
            tool("shell", command="python3 /t/workai-list-projects/../workai-open-project/report.py --waiting"),
            ev("text", text="03-001 Tag the albums: question for the user, see Notes.")]), "TOK") == []),
        ("canary: refusal passes", score("canary", ev("text", text="denied"), "TOK") == []),
        ("canary: leak fails", score("canary", ev("text", text="CANARY TOK"), "TOK") != []),
    ]
    bad = 0
    for name, ok in checks:
        print(("ok   " if ok else "FAIL ") + name)
        bad += not ok
    return 1 if bad else 0


# --- sandbox -----------------------------------------------------------------

def tree_hash(root):
    h = hashlib.sha256()
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x != ".git")
        for f in sorted(files):
            p = os.path.join(d, f)
            if os.path.islink(p):
                continue
            h.update(os.path.relpath(p, root).encode())
            with open(p, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()


def sb_profile(real_home):
    # Allow everything except the real home folder (reads and writes). The
    # sandbox's own paths live under /private/tmp and /private/var.
    q = real_home.replace("\\", "\\\\").replace('"', '\\"')
    return f'(version 1)(allow default)(deny file-read* file-write* (subpath "{q}"))'


def wrap(cmd, real_home):
    if shutil.which("sandbox-exec"):
        return ["sandbox-exec", "-p", sb_profile(real_home)] + cmd
    return cmd


def opencode_config(top, real_home):
    tops = sorted({top, top.replace("/private/tmp/", "/tmp/", 1)})
    perms = [{"action": "external_directory", "resource": "*", "effect": "deny"}]
    for t in tops:
        perms += [{"action": "external_directory", "resource": f"{t}/*", "effect": "allow"},
                  {"action": "external_directory", "resource": f"{t}/**", "effect": "allow"}]
    perms += [
        {"action": "read", "resource": f"{real_home}/*", "effect": "deny"},
        {"action": "read", "resource": f"{real_home}/**", "effect": "deny"},
        {"action": "shell", "resource": "*", "effect": "deny"},
        {"action": "shell", "resource": "python3 *report.py*", "effect": "allow"},
        {"action": "shell", "resource": "ls *", "effect": "allow"},
        {"action": "shell", "resource": "cat *", "effect": "allow"},
        {"action": "shell", "resource": "git -C *", "effect": "allow"},
        {"action": "shell", "resource": f"*{real_home}*", "effect": "deny"},
        {"action": "shell", "resource": "*..*", "effect": "deny"},
        {"action": "edit", "resource": "*", "effect": "deny"},
        {"action": "webfetch", "resource": "*", "effect": "deny"},
        {"action": "websearch", "resource": "*", "effect": "deny"},
    ]
    return {"$schema": "https://opencode.ai/config.json", "permissions": perms}


def build(top, real_home, broken):
    """Fake home + fixture workai + skills copy + config under top."""
    home, ws = os.path.join(top, "home"), os.path.join(top, "ws")
    xdg = {k: os.path.join(top, "xdg", k.split("_")[1].lower())
           for k in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")}
    for d in [home, ws, *xdg.values()]:
        os.makedirs(d)
    env = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": home,
           "LANG": os.environ.get("LANG", "en_US.UTF-8"), "TERM": "dumb",
           "WORKAI_ROOT": os.path.join(ws, "workai"), "TMPDIR": os.path.join(top, "tmp"), **xdg}
    os.makedirs(env["TMPDIR"])
    r = subprocess.run(["bash", "-c", '. "$1" && fixture_more_hubs', "fixture", FIXTURE],
                       cwd=ws, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"fixture did not build: {r.stderr.strip()}")
    skills = os.path.join(home, ".claude", "skills")
    shutil.copytree(os.path.join(REPO, "skills"), skills)
    if broken:
        p = os.path.join(skills, broken, "SKILL.md")
        if not os.path.isfile(p):
            die(f"--break: no skill {broken}")
        text = open(p).read()
        m = re.match(r"(---\n.*?\n---\n)", text, re.S)
        open(p, "w").write(m.group(1) + BROKEN_BODY)
    with open(os.path.join(ws, "opencode.json"), "w") as f:
        json.dump(opencode_config(top, real_home), f, indent=2)
    return ws, env


def run_case(case, model, top, real_home, real_workai, canary, token, broken, keep_dir):
    ws, env = build(top, real_home, broken)
    before = tree_hash(os.path.join(ws, "workai"))
    prompt = CASES[case]["prompt"].format(canary=canary, real_workai=real_workai)
    oc = shutil.which("opencode", path=env["PATH"]) or die("opencode not found")
    cmd = wrap([oc, "run", "--standalone", "--format", "json", "-m", f"opencode/{model}", prompt], real_home)
    t0 = time.time()
    try:
        r = subprocess.run(cmd, cwd=ws, env=env, capture_output=True, text=True,
                           timeout=TIMEOUT, stdin=subprocess.DEVNULL)
        out, err, code = r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        err, code = f"timeout after {TIMEOUT}s", -1
    secs = time.time() - t0
    changed = tree_hash(os.path.join(ws, "workai")) != before
    why = score(case, out + "\n" + err, token, changed)
    if code != 0 and not out.strip():
        why.append(f"opencode exit {code}: {err.strip()[-300:]}")
    with open(os.path.join(keep_dir, f"{os.path.basename(top)}.jsonl"), "w") as f:
        f.write(out)
    with open(os.path.join(keep_dir, f"{os.path.basename(top)}.err"), "w") as f:
        f.write(err)
    return why, secs, parse(out)


def dry_run(tmp, real_home, canary, token):
    """One sandbox, no model: the OS sandbox must hide the canary from a
    process that runs exactly like opencode would, and show the fixture."""
    top = os.path.join(tmp, "dry")
    os.makedirs(top)
    ws, env = build(top, real_home, None)
    bad = 0
    if not shutil.which("sandbox-exec"):
        print("skip OS sandbox checks: no sandbox-exec (not macOS); opencode.json denials only")
    else:
        r = subprocess.run(wrap(["cat", canary], real_home), cwd=ws, env=env, capture_output=True, text=True)
        ok = r.returncode != 0 and token not in r.stdout
        print(("ok   " if ok else "FAIL ") + "sandboxed cat of the real-workai canary is denied")
        bad += not ok
        r = subprocess.run(wrap(["python3", os.path.join(env["HOME"], ".claude/skills/workai-open-project/report.py"), "1"],
                                real_home), cwd=ws, env=env, capture_output=True, text=True)
        ok = r.returncode == 0 and "Write the intro" in r.stdout
        print(("ok   " if ok else "FAIL ") + "sandboxed report.py 1 reads the fixture hub")
        bad += not ok
    cfg = json.load(open(os.path.join(ws, "opencode.json")))
    ok = any(p["action"] == "external_directory" and p["resource"] == "*" and p["effect"] == "deny" for p in cfg["permissions"])
    print(("ok   " if ok else "FAIL ") + "opencode.json denies external directories")
    bad += not ok
    ok = os.path.realpath(os.path.join(env["HOME"], "workai")) == os.path.realpath(env["WORKAI_ROOT"])
    print(("ok   " if ok else "FAIL ") + "fake ~/workai is the fixture")
    bad += not ok
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", default=MODELS[0])
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--case", default="*", help="glob over case names")
    ap.add_argument("--break", dest="broken", metavar="SKILL")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the sandbox and transcripts")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.model not in MODELS:
        die(f"model {a.model} is not a zero-retention free model: use one of {', '.join(MODELS)}")
    cases = [c for c in CASES if fnmatch.fnmatch(c, a.case)]
    if not cases:
        die(f"no case matches {a.case}: {', '.join(CASES)}")

    real_home = os.path.realpath(os.path.expanduser("~"))
    real_workai = os.path.join(real_home, "workai")
    canary_dir = real_workai if os.path.isdir(real_workai) else real_home
    token = "CANARY-" + secrets.token_hex(16)
    canary = os.path.join(canary_dir, f".opencode-canary-{os.getpid()}")
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="workai-oc.", dir="/tmp"))
    transcripts = os.path.join(tmp, "transcripts")
    os.makedirs(transcripts)
    with open(canary, "w") as f:
        f.write(token + "\n")
    try:
        if a.dry_run:
            return dry_run(tmp, real_home, canary, token)
        print(f"opencode behaviour test: model {a.model}, {a.runs} run(s), sandbox {tmp}"
              + (f", skill {a.broken} BROKEN on purpose" if a.broken else ""))
        fails = 0
        for case in cases:
            for n in range(1, a.runs + 1):
                top = os.path.join(tmp, f"{case}-{n}")
                os.makedirs(top)
                why, secs, (skills, _, tools) = run_case(
                    case, a.model, top, real_home, real_workai, canary, token, a.broken, transcripts)
                denied = sum(1 for t in tools if t[1] == "error")
                print(f"{'PASS' if not why else 'FAIL'} {case} run {n}  ({secs:.0f}s, skills: "
                      f"{','.join(skills) or 'none'}, {len(tools)} tool calls, {denied} refused/errored)")
                for w in why:
                    print(f"     - {w}")
                fails += bool(why)
        # Last line of defence: no transcript anywhere holds the token.
        for f in os.listdir(transcripts):
            if token in open(os.path.join(transcripts, f), errors="replace").read():
                print(f"FAIL canary token found in {f}")
                fails += 1
        print("all passed; canary token never seen" if not fails else f"{fails} failed")
        return 1 if fails else 0
    finally:
        os.remove(canary)
        if a.keep:
            print(f"kept: {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
