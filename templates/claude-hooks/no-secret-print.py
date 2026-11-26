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
# A pipeline stage that turns what it reads into something safe to print.
SAFE_SINK_STAGE = re.compile(
    r"^(?:cut\s+(?:-d\s*['\"]?=['\"]?\s+-f\s*1|-f\s*1\s+-d\s*['\"]?=['\"]?)|wc|sha\d*sum|md5sum|b2sum)(?:\s+-[a-z]+)*\s*$"
)
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Wrappers that run another command, with the options of each that take a separate argument.
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R", "-T"},
    "env": {"-u", "-C", "-S"},
    "nice": {"-n"},
    "time": {"-f", "-o"},
    "nohup": set(), "command": set(), "builtin": set(), "exec": set(), "stdbuf": {"-i", "-o", "-e"},
    "timeout": {"-s", "-k"},
}
GREP_UNSAFE_OPTS = re.compile(r"^-(?:[a-zA-Z]*[vABC]|-invert-match|-after-context|-before-context|-context)")
DENY_FILE = (
    "Blocked: this would print the contents of {f}, which may hold secrets. "
    "Read only exact, non-secret keys, each spelled out and followed by '=' "
    "(grep -E '^(APP_ENV|COMPOSE_PROJECT_NAME)=' file), or list names with `cut -d= -f1`, "
    "or compare values by hash/length, or redirect the output to a file. "
    "A prefix pattern like ^(COMPOSE) also matches COMPOSER_GITHUB_TOKEN."
)


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def split_unquoted(text: str, seps):
    """Split text on any of seps (longest first) outside single or double quotes."""
    out, buf, q, i = [], "", None, 0
    seps = sorted(seps, key=len, reverse=True)
    while i < len(text):
        c = text[i]
        if q:
            buf += c
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            buf += c
        else:
            sep = next((x for x in seps if text.startswith(x, i)), None)
            if sep:
                out.append(buf)
                buf = ""
                i += len(sep)
                continue
            buf += c
        i += 1
    out.append(buf)
    return [p.strip() for p in out]


def segments(cmd: str):
    """Commands joined by ; && || or newlines; each keeps its pipeline."""
    return [s for s in split_unquoted(cmd, [";", "\n", "&&", "||"]) if s]


def stages(pipeline: str):
    return split_unquoted(pipeline, ["|"])


def unquoted(stage: str) -> str:
    """The stage with every quoted span blanked, so quoted text never reads as shell syntax."""
    return re.sub(r"'[^']*'|\"(?:\\.|[^\"\\])*\"", "''", stage)


def words(stage: str):
    """The command words after any wrappers (sudo, env, nice ...) and VAR=value assignments."""
    try:
        w = shlex.split(stage, comments=False)
    except ValueError:
        return None
    w = [a for a in w if not re.match(r"^\d*>>?|^\d*<", a)]
    while w:
        head = w[0].rsplit("/", 1)[-1]
        if NAME.match(w[0]):
            w = w[1:]
            continue
        if head not in WRAPPERS:
            break
        takes_arg = WRAPPERS[head]
        rest, i = w[1:], 0
        while i < len(rest) and (rest[i].startswith("-") or (head == "env" and NAME.match(rest[i]))):
            i += 2 if rest[i] in takes_arg else 1
        if head == "nice" and i < len(rest) and re.fullmatch(r"-?\d+", rest[i]):
            i += 1
        if head == "timeout" and i < len(rest):
            i += 1  # the duration
        if i >= len(rest):
            # A wrapper with no command after it: `env` and `sudo -n env` print the environment.
            return ["env"] if head == "env" else []
        w = rest[i:]
    return w


def redirected(stage: str) -> bool:
    """stdout of this stage goes to a file (an unquoted > or >> to something other than a terminal)."""
    m = re.search(r"(?<![0-9&<>])>>?\s*([^\s&|;<>]+)", unquoted(stage))
    # A quoted target (blanked to '') is a file path; only an unquoted terminal device is not a file.
    return bool(m) and m.group(1) not in ("/dev/stdout", "/dev/stderr", "/dev/tty")


def output_is_safe(pipe, idx: int) -> bool:
    """Everything stage idx prints ends up in a file or a safe sink, and nothing on the way copies it out."""
    for st in pipe[idx:]:
        if redirected(st):
            return True
        w = words(st) or []
        if w and w[0].rsplit("/", 1)[-1] == "tee":
            return False
    last = pipe[-1].strip()
    return len(pipe) - 1 > idx and bool(SAFE_SINK_STAGE.match(last))


def exact_key_grep(w) -> bool:
    """grep that prints only keys named in full, each followed by '=' and none secret-looking."""
    opts = [a for a in w[1:] if a.startswith("-")]
    if any(GREP_UNSAFE_OPTS.match(o) for o in opts):
        return False
    if any(re.match(r"^-[a-zA-Z]*[clqL]", o) or o in ("--count", "--quiet", "--silent", "--files-with-matches") for o in opts):
        return True
    args = [a for a in w[1:] if not a.startswith("-")]
    if not args:
        return False
    m = re.fullmatch(r"\^\(?([A-Za-z0-9_]+(?:\|[A-Za-z0-9_]+)*)\)?=(?:\.\*)?", args[0])
    if not m:
        return False
    return not any(SECRETISH.search(k) for k in m.group(1).split("|"))


def check(cmd: str) -> None:
    for seg in segments(cmd):
        pipe = stages(seg)
        for idx, st in enumerate(pipe):
            w = words(st)
            if not w:
                continue
            prog = w[0].rsplit("/", 1)[-1]
            safe = output_is_safe(pipe, idx)
            # Environment dumps.
            if prog in ("env", "printenv"):
                operands = [a for a in w[1:] if not a.startswith("-")]
                if (not operands or any(SECRETISH.search(a) for a in operands)) and not safe:
                    deny("This would print environment values, which include secrets. Check a variable by "
                         "length or hash instead, e.g. `[ -n \"$NAME\" ] && echo set`, or list names only with "
                         "`env | cut -d= -f1`.")
            if (prog == "export" and w[1:2] == ["-p"]) or (prog == "set" and len(w) == 1):
                if not safe:
                    deny("This would print every shell variable, secrets included. List names only.")
            if prog == "docker" and len(w) > 2 and w[1] == "compose" and "config" in w[2:]:
                if not any(a in w for a in ("--services", "--volumes", "--profiles", "--images", "--quiet", "-q")) and not safe:
                    deny("`docker compose config` prints resolved environment values, secrets included. "
                         "Use `--services`, `--profiles` or `--images`, or redirect it to a file.")
            if prog == "docker" and len(w) > 1 and w[1] in ("inspect", "container") and "inspect" in w[1:3]:
                if not any(a in ("-f", "--format") or a.startswith("--format=") for a in w) and not safe:
                    deny("`docker inspect` prints the container's environment, secrets included. "
                         "Use `--format` with the exact fields you need.")
            # Secret files read by a printing tool.
            if prog not in READERS:
                continue
            files = [f for f in SECRET_FILE.findall(unquoted(st) + " " + " ".join(w[1:])) if not SAFE_FILE.search(f)]
            if not files:
                continue
            if prog == "sed" and any(a.startswith("-i") or a == "--in-place" for a in w[1:]):
                continue
            if prog in ("grep", "egrep", "fgrep", "rg") and exact_key_grep(w):
                continue
            if safe:
                continue
            deny(DENY_FILE.format(f=files[0]))


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
