#!/usr/bin/env python3
"""Claude Code PreToolUse hook: stop history-wide git searches in partial clones.

In a partial clone (for example `--filter=blob:none`), `git log -S/-G/-p/
--stat/-L/--follow` and `git blame` download every old file version they
touch, one fetch at a time, with an auto-gc after each. Over a long history
that runs for hours and can fill the disk. This hook denies those commands in
a partial clone and tells the agent to search with git grep or to make the
clone full first.

Short runs (`git log -p -3`, `-n 20`) are allowed. Fails open: any error, or
anything it can't parse, lets the command run.
"""
import json
import os
import re
import shlex
import subprocess
import sys

CONTENT_FLAGS = re.compile(
    r"^(-S.*|-G.*|-p|-u|--patch|-L.*|--follow|--stat.*|--numstat|--shortstat"
    r"|--dirstat.*|--word-diff.*|--pickaxe-.*|--patch-with-.*|--cc|-c|-m)$"
)
SMALL_LIMIT = 50


def segments(command):
    # Split on shell separators; good enough for agent one-liners.
    return re.split(r"\|\||&&|;|\||\n", command)


def tokens(segment):
    try:
        return shlex.split(segment, comments=True)
    except ValueError:
        return segment.split()


def promisor_remote(path):
    """Name of the repo's promisor remote, or None if it is a full clone."""
    try:
        out = subprocess.run(
            ["git", "-C", path, "config", "--get-regexp",
             r"^(remote\..*\.promisor|remote\..*\.partialclonefilter|extensions\.partialclone)$"],
            capture_output=True, text=True, timeout=3,
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        key, _, value = line.partition(" ")
        value = value.strip()
        if key.endswith(".promisor") and value.lower() != "true":
            continue
        if key == "extensions.partialclone":
            return value or "origin"
        return key.split(".")[1]
    return None


def limited(args):
    # A small explicit count (git log -p -3, -n 5, --max-count=10) is fine.
    for i, a in enumerate(args):
        m = re.match(r"^-(\d+)$", a) or re.match(r"^-n(\d+)$", a) or re.match(r"^--max-count=(\d+)$", a)
        if m and int(m.group(1)) <= SMALL_LIMIT:
            return True
        if a in ("-n", "--max-count") and i + 1 < len(args) and args[i + 1].isdigit():
            if int(args[i + 1]) <= SMALL_LIMIT:
                return True
    return False


def risky_git(toks, cwd):
    """Return (repo_dir, subcommand) if toks run a risky git command."""
    if "git" not in toks:
        return None
    i = toks.index("git") + 1
    repo = cwd
    while i < len(toks) and toks[i].startswith("-"):
        opt = toks[i]
        if opt == "-C" and i + 1 < len(toks):
            repo = os.path.join(repo, os.path.expanduser(toks[i + 1]))
            i += 2
        elif opt == "-c" and i + 1 < len(toks):
            i += 2
        else:
            i += 1
    if i >= len(toks):
        return None
    sub, args = toks[i], toks[i + 1:]
    if sub in ("blame", "annotate"):
        return repo, sub
    if sub in ("log", "whatchanged"):
        if any(CONTENT_FLAGS.match(a) for a in args) and not limited(args):
            return repo, sub
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command") or ""
    if "git" not in command:
        return
    cwd = data.get("cwd") or os.getcwd()
    for seg in segments(command):
        toks = tokens(seg.strip())
        if not toks:
            continue
        if toks[0] == "cd":
            target = os.path.expanduser(toks[1]) if len(toks) > 1 else os.path.expanduser("~")
            cwd = os.path.normpath(os.path.join(cwd, target))
            continue
        hit = risky_git(toks, cwd)
        remote = promisor_remote(hit[0]) if hit else None
        if remote:
            repo, sub = hit
            reason = (
                f"Stopped: {repo} is a partial clone, so this `git {sub}` would download the old "
                "version of every file it touches, one fetch at a time, and can fill the disk. "
                "Do one of these instead:\n"
                "1. Search without history: `git grep -n 'X' origin/master -- <paths>`. To find the "
                "commit that added a file, `git log --no-renames --diff-filter=A --format='%h %s' "
                "origin/master -- <file>` needs no file contents. `gh search code` or the GitHub API "
                "work too.\n"
                f"2. Or make the clone full first, then rerun: `git config --unset "
                f"remote.{remote}.partialclonefilter; git config --unset remote.{remote}.promisor; "
                f"git -c gc.auto=0 fetch --refetch --no-auto-gc {remote}`."
            )
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }}))
            return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
