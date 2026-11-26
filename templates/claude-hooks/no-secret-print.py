#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuse commands that would print a secret into the transcript.

Anything a command prints lands in the session transcript, so a quick look at a settings file can publish a
credential. The classic slip is a prefix pattern: grep -E "^(COMPOSE|...)" .env also matches
COMPOSER_GITHUB_TOKEN.

Blocks, unless the output provably goes somewhere other than the transcript:
  * reading a secret-bearing file (.env*, auth.json, .netrc, *.pem, id_rsa*, credentials, .secrets/...,
    secrets.json, secret.txt) with a printing tool (cat, grep, sed, awk, head, tail, ...);
  * dumping the environment (bare `env` / `printenv` / `export -p` / `set`, or printenv of a secret-like name);
  * `docker compose config` and `docker inspect` without a narrowing flag (both print resolved env values).

Allowed forms:
  * exact-key reads: grep -E '^(KEY_ONE|KEY_TWO)=' file, where every key is spelled out and followed by "=",
    and no key looks secret (TOKEN, SECRET, PASSWORD, KEY, DSN, AUTH, CREDENTIAL, PRIVATE);
  * counts and names only: grep -c/-l/-q, `| cut -d= -f1`, `| wc`, `| sha256sum`/`md5sum`;
  * sourcing (`. file`, `source file`, `--env-file file`), copying, chmod, and editing in place (sed -i);
  * any reader whose stdout is redirected to a file.
Fails open (allows) if it cannot parse the command, so it never blocks unrelated work.
"""
import json
import re
import shlex
import sys

SECRET_FILE = re.compile(
    r"(?:^|[\s/'\"=:])("
    r"\.env(?:\.[\w.-]+)?|[\w.-]+\.env|auth\.json|\.netrc|\.pgpass|[\w.-]*credentials(?:\.json)?|"
    r"id_(?:rsa|dsa|ecdsa|ed25519)\w*|[\w.-]+\.(?:pem|key|p12|pfx)|\.secrets/[\w./-]*|[\w.-]*secrets?(?:\.(?:json|txt|ya?ml|key|env|ini|conf))?"
    r")(?=$|[\s'\";|)&>])",
    re.I,
)
SAFE_FILE = re.compile(r"\.env\.(?:example|dist|sample|template)$|\.env\.test$", re.I)
READERS = {
    "cat", "tac", "less", "more", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "gawk",
    "strings", "xxd", "od", "hexdump", "nl", "bat", "diff", "sort", "uniq", "column", "tr", "jq", "yq", "paste",
}
SECRETISH = re.compile(r"TOKEN|SECRET|PASS|KEY|DSN|AUTH|CREDENTIAL|PRIVATE|COOKIE|SESSION", re.I)
SAFE_SINK = re.compile(r"\|\s*(?:cut\s+-d\s*['\"]?=['\"]?\s+-f\s*1\b|wc\b|sha\d*sum\b|md5sum\b)")
WRAPPERS = {"sudo", "-n", "env", "time", "nice", "command", "builtin", "exec", "xargs"}


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def segments(cmd: str):
    """Split on ; && || and newlines (not inside quotes); keep pipelines together."""
    out, buf, q = [], "", None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            buf += c
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            buf += c
        elif c in ";\n" or cmd[i:i + 2] in ("&&", "||"):
            out.append(buf)
            buf = ""
            i += 1 if c in ";\n" else 2
            continue
        else:
            buf += c
        i += 1
    out.append(buf)
    return [s.strip() for s in out if s.strip()]


def stages(pipeline: str):
    parts, buf, q = [], "", None
    for c in pipeline:
        if q:
            buf += c
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            buf += c
        elif c == "|":
            parts.append(buf)
            buf = ""
        else:
            buf += c
    parts.append(buf)
    return [p.strip() for p in parts]


def words(stage: str):
    try:
        w = shlex.split(stage, comments=False)
    except ValueError:
        return None
    while w and (w[0] in WRAPPERS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w[0])):
        rest = w[1:]
        # `env` with nothing after it (or only VAR=value pairs) is itself the command: it prints the environment.
        if w[0] == "env" and not any(not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a) and not a.startswith("-") for a in rest):
            return ["env"]
        w = rest
    return w


def redirected(stage: str) -> bool:
    m = re.search(r"(?<![0-9&<])>>?\s*([^\s&|;]+)", stage)
    return bool(m) and m.group(1) not in ("/dev/stdout", "/dev/stderr", "/dev/tty")


def exact_key_grep(w) -> bool:
    """grep whose pattern names every key in full, each followed by '=' and none secret-looking."""
    opts = [a for a in w[1:] if a.startswith("-")]
    if any(re.match(r"^-[a-zA-Z]*[clqL]", o) or o in ("--count", "--quiet", "--silent", "--files-with-matches") for o in opts):
        return True
    args = [a for a in w[1:] if not a.startswith("-")]
    if not args:
        return False
    pat = args[0]
    m = re.fullmatch(r"\^?\(?([A-Za-z0-9_|]+)\)?=.*", pat)
    if not m:
        return False
    return not any(SECRETISH.search(k) for k in m.group(1).split("|"))


def check(cmd: str) -> None:
    for seg in segments(cmd):
        pipe = stages(seg)
        rest_has_safe_sink = bool(SAFE_SINK.search(seg))
        for idx, st in enumerate(pipe):
            w = words(st)
            if not w:
                continue
            prog = w[0].rsplit("/", 1)[-1]
            later_redirect = any(redirected(p) for p in pipe[idx:])
            # Environment dumps.
            if prog in ("env", "printenv") and (len(w) == 1 or any(SECRETISH.search(a) for a in w[1:])):
                if not (later_redirect or rest_has_safe_sink):
                    deny("This would print environment values, which include secrets. Check a variable by "
                         "length or hash instead, e.g. `[ -n \"$NAME\" ] && echo set`, or list names only with "
                         "`env | cut -d= -f1`.")
            if prog == "export" and w[1:2] == ["-p"] or (prog == "set" and len(w) == 1):
                if not (later_redirect or rest_has_safe_sink):
                    deny("This would print every shell variable, secrets included. List names only.")
            if prog == "docker" and len(w) > 2 and w[1] == "compose" and "config" in w[2:]:
                if not any(a in w for a in ("--services", "--volumes", "--profiles", "--images", "--quiet", "-q")):
                    deny("`docker compose config` prints resolved environment values, secrets included. "
                         "Use `--services`, `--profiles` or `--images`, or read one exact key.")
            if prog == "docker" and len(w) > 1 and w[1] in ("inspect", "container") and "inspect" in w[1:3]:
                if not any(a in ("-f", "--format") or a.startswith("--format=") for a in w):
                    deny("`docker inspect` prints the container's environment, secrets included. "
                         "Use `--format` with the exact fields you need.")
            # Secret files read by a printing tool.
            if prog not in READERS:
                continue
            files = [f for f in SECRET_FILE.findall(st) if not SAFE_FILE.search(f)]
            if not files:
                continue
            if prog == "sed" and any(a.startswith("-i") or a == "--in-place" for a in w[1:]):
                continue
            if prog in ("grep", "egrep", "fgrep", "rg") and exact_key_grep(w):
                continue
            if later_redirect or rest_has_safe_sink:
                continue
            deny(
                f"Blocked: this would print the contents of {files[0]}, which may hold secrets. "
                "Read only exact, non-secret keys, each spelled out and followed by '=' "
                "(grep -E '^(COMPOSE_PROJECT_NAME|YEARBOOK_NETWORK)=' file), or list names with "
                "`cut -d= -f1`, or compare values by hash/length, or redirect the output to a file. "
                "A prefix pattern like ^(COMPOSE) also matches COMPOSER_GITHUB_TOKEN."
            )


def main() -> None:
    try:
        data = json.load(sys.stdin)
        cmd = data.get("tool_input", {}).get("command", "")
    except Exception:
        return
    if isinstance(cmd, str) and cmd:
        try:
            check(cmd)
        except SystemExit:
            raise
        except Exception:
            return


if __name__ == "__main__":
    main()
