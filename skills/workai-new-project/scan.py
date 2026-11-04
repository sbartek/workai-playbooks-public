#!/usr/bin/env python3
"""Scan a git repo for secrets and identity documents before it is pushed.

Usage: scan.py REPO

Looks at everything a push could send: every file in every commit reachable
from any ref (the whole history, not only the last commit). Two kinds of hit:

  secret    credentials in file contents (private keys, GitHub/Google/AWS/
            Anthropic/OpenAI/Slack/Stripe tokens, URLs with a password,
            key=value assignments that look like a real secret) and
            credential files by name (.p12, .pem, id_ed25519, .env, ...)
  identity  scans of identity documents by file name (DNI, NIE, passport,
            birth certificate, signature, ...) and Spanish DNI/NIE numbers
            whose control letter is valid

Hits are printed as `path[:line]  kind/rule`; matched values are never
printed. Exit 0 = clean, 1 = hits (do not push), 2 = could not scan.

If `gitleaks` is on PATH it also runs (`--redact`); set WORKAI_SCAN_NO_GITLEAKS=1
to skip it. A hit that is not a problem goes in `.workai-scan-allow` at the
repo root, one `path-glob [rule]` per line (rule omitted = every rule). Fix
real hits by removing the file from history, not by allowing them.
"""
import fnmatch
import os
import re
import shutil
import subprocess
import sys

MAX_BYTES = 5 * 1024 * 1024

DOC_EXT = {"pdf", "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp",
           "gif", "bmp", "doc", "docx", "odt"}
# One word of a file name (split on separators and camelCase), lowercase.
ID_WORDS = {"dni", "nie", "nif", "tie", "pasaporte", "passport", "paszport",
            "pasaport", "dowod", "dowód", "dowodosobisty", "idcard", "pesel",
            "nuss", "firma", "signature", "podpis", "visa", "wiza"}
ID_PAIRS = {("id", "card"), ("id", "scan"), ("birth", "certificate"),
            ("certificado", "nacimiento"), ("partida", "nacimiento"),
            ("akt", "urodzenia"), ("libro", "familia"), ("driving", "licence"),
            ("driving", "license"), ("permiso", "conducir"),
            ("carnet", "conducir"), ("prawo", "jazdy"),
            ("residence", "permit"), ("tarjeta", "residencia"),
            ("dowod", "osobisty"), ("dowód", "osobisty")}
CRED_EXT = {"p12", "pfx", "jks", "keystore", "pem", "key", "kdbx", "ppk"}
CRED_NAMES = {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".pgpass",
              "credentials.json", "token.json", "token.pickle", ".npmrc",
              ".pypirc", ".git-credentials"}
CRED_GLOBS = ["client_secret*.json", "service-account*.json", ".env", ".env.*"]
CRED_SAFE = {".env.example", ".env.sample", ".env.template"}

SECRET_RES = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----")),
    ("aws-access-key", re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("google-oauth-token", re.compile(r"\bya29\.[0-9A-Za-z_\-]{20,}|\b1//0[0-9A-Za-z_\-]{30,}")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{20,}")),
    ("openai-key", re.compile(r"\bsk-(proj-)?[A-Za-z0-9_\-]{32,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}")),
    ("stripe-key", re.compile(r"\b[sr]k_live_[A-Za-z0-9]{20,}")),
    ("url-password", re.compile(r"\b[a-z][a-z0-9+.\-]*://[^/\s:@'\"]+:([^/\s@'\"]{6,})@")),
]
ASSIGN_RE = re.compile(
    r"(?i)\b[\w.\-]*(password|passwd|pwd|secret|token|api[_\-]?key|access[_\-]?key)[\w.\-]*"
    r"[\"']?\s*[:=]\s*[\"']?([A-Za-z0-9_\-+/=.!@#%^&*~]{12,})")
PLACEHOLDER_RE = re.compile(r"(?i)^(x+|\*+|.*(your|example|changeme|placeholder|dummy|redacted|sample).*)$")
DNI_RE = re.compile(r"\b([XYZ]?)(\d{7,8})-?([A-Z])\b")
DNI_LETTERS = "TRWAGMYFPDXBNJZSQVHLCKE"


def words(name):
    stem = name.rsplit(".", 1)[0] if "." in name.lstrip(".") else name
    stem = re.sub(r"([a-z])([A-Z])", r"\1-\2", stem)
    return [w for w in re.split(r"[^0-9a-zA-Zà-žÀ-Ž]+", stem.lower()) if w]


def name_hits(path):
    base = path.rsplit("/", 1)[-1]
    low = base.lower()
    ext = low.rsplit(".", 1)[-1] if "." in low.lstrip(".") else ""
    hits = []
    if low not in CRED_SAFE and (low in CRED_NAMES or ext in CRED_EXT
                                 or any(fnmatch.fnmatch(low, g) for g in CRED_GLOBS)):
        hits.append(("secret", "credential-file"))
    if ext in DOC_EXT:
        ws = words(base)
        if any(w in ID_WORDS for w in ws) or any(p in ID_PAIRS for p in zip(ws, ws[1:])):
            hits.append(("identity", "identity-document-name"))
    return hits


def valid_dni(prefix, digits, letter):
    if prefix:
        if len(digits) != 7:
            return False
        digits = str("XYZ".index(prefix)) + digits
    elif len(digits) != 8:
        return False
    return DNI_LETTERS[int(digits) % 23] == letter


def content_hits(text):
    for no, line in enumerate(text.splitlines(), 1):
        for rule, rx in SECRET_RES:
            if rx.search(line):
                yield no, "secret", rule
        for m in ASSIGN_RE.finditer(line):
            value = m.group(2)
            if (re.search(r"[A-Za-z]", value) and re.search(r"\d", value)
                    and not PLACEHOLDER_RE.match(value)):
                yield no, "secret", "assigned-secret"
                break
        for m in DNI_RE.finditer(line):
            if valid_dni(*m.groups()):
                yield no, "identity", "dni-nie-number"
                break


def git(repo, *args, data=None):
    return subprocess.run(["git", "-C", repo, *args], input=data,
                          capture_output=True, check=True).stdout


def load_allow(repo):
    try:
        lines = open(os.path.join(repo, ".workai-scan-allow"), encoding="utf-8").read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if line:
            parts = line.split()
            out.append((parts[0], parts[1] if len(parts) > 1 else None))
    return out


def allowed(allow, path, rule):
    return any(fnmatch.fnmatch(path, g) and (r is None or r == rule) for g, r in allow)


def scan(repo):
    try:
        has_commit = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", "HEAD"],
                                    capture_output=True).returncode == 0
        refs = git(repo, "for-each-ref", "--format=%(refname)").split()
        if not has_commit and not refs:
            return [], None
        objs = git(repo, "rev-list", "--objects", "--all").decode("utf-8", "replace").splitlines()
    except (subprocess.CalledProcessError, OSError) as e:
        return None, f"git failed in {repo}: {e}"
    pairs = {}
    for line in objs:
        sha, _, path = line.partition(" ")
        if path:
            pairs.setdefault(path, set()).add(sha)
    # rev-list names each blob once; files with equal contents need the log.
    try:
        names = set(git(repo, "log", "--all", "--no-renames", "--format=", "--name-only",
                        "-z").decode("utf-8", "replace").split("\0"))
    except (subprocess.CalledProcessError, OSError) as e:
        return None, f"git log failed in {repo}: {e}"
    hits = set()
    for path in (names | set(pairs)) - {""}:
        for kind, rule in name_hits(path.strip("\n")):
            hits.add((path, 0, kind, rule))
    shas = sorted({s for ss in pairs.values() for s in ss})
    path_of = {}
    for path, ss in pairs.items():
        for s in ss:
            path_of.setdefault(s, []).append(path)
    if shas:
        try:
            info = git(repo, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)",
                       data="\n".join(shas).encode()).decode().splitlines()
        except (subprocess.CalledProcessError, OSError) as e:
            return None, f"git cat-file failed in {repo}: {e}"
        blobs = [l.split()[0] for l in info if len(l.split()) == 3
                 and l.split()[1] == "blob" and int(l.split()[2]) <= MAX_BYTES]
        try:
            out = git(repo, "cat-file", "--batch", data="\n".join(blobs).encode())
        except (subprocess.CalledProcessError, OSError) as e:
            return None, f"git cat-file failed in {repo}: {e}"
        pos, contents = 0, []
        while pos < len(out):
            nl = out.index(b"\n", pos)
            sha, _, size = out[pos:nl].decode().split()
            start = nl + 1
            contents.append((sha, out[start:start + int(size)]))
            pos = start + int(size) + 1
        for sha, raw in contents:
            if b"\0" in raw[:8000]:
                continue
            found = list(content_hits(raw.decode("utf-8", "replace")))
            for path in path_of[sha]:
                for no, kind, rule in found:
                    hits.add((path, no, kind, rule))
    allow = load_allow(repo)
    return sorted(h for h in hits if not allowed(allow, h[0], h[3])), None


def gitleaks(repo):
    exe = shutil.which("gitleaks")
    if not exe or os.environ.get("WORKAI_SCAN_NO_GITLEAKS") == "1":
        return None
    for args in (["git", "--no-banner", "--redact", "--exit-code", "1", repo],
                 ["detect", "--no-banner", "--redact", "--exit-code", "1", "--source", repo]):
        r = subprocess.run([exe, *args], capture_output=True, text=True)
        if "unknown command" in (r.stderr + r.stdout) and args[0] == "git":
            continue
        return r
    return None


def main(argv):
    if len(argv) != 2:
        print(__doc__.split("\n\n")[1])
        return 2
    repo = argv[1]
    hits, err = scan(repo)
    if err:
        print(f"scan: {err}")
        return 2
    for path, no, kind, rule in hits:
        print(f"{path}{':' + str(no) if no else ''}  {kind}/{rule}")
    gl = gitleaks(repo)
    gl_hit = gl is not None and gl.returncode == 1
    if gl_hit:
        print("gitleaks found leaks (values redacted):")
        print("\n".join("  " + l for l in (gl.stdout + gl.stderr).splitlines() if l.strip()))
    elif gl is not None and gl.returncode not in (0, 1):
        print(f"scan: gitleaks failed (exit {gl.returncode})")
        return 2
    if hits or gl_hit:
        print(f"scan: {len(hits)} hit(s) in {repo}{' + gitleaks' if gl_hit else ''}; do not push. "
              "Remove the file from history, or list a false positive in .workai-scan-allow.")
        return 1
    print(f"scan: clean ({repo}{', gitleaks too' if gl is not None else ', built-in rules only: gitleaks not installed'})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
