#!/usr/bin/env python3
"""Claude Code PreToolUse hook: stop history-wide git searches in partial clones.

In a partial clone (for example `--filter=blob:none`), `git log -S/-G/-p/
--stat/-L/--follow` and `git blame` download every old file version they
touch, one fetch at a time, with an auto-gc after each. Over a long history
that runs for hours and can fill the disk. This hook denies those commands in
a partial clone and tells the agent to search with git grep or to make the
clone full first.

Short runs (`git log -p -3`, `-n 20`) are allowed, but searches (-S, -G, -L)
are not: they walk history until they find enough matches. Fails open: any error, or
anything it can't parse, lets the command run.
"""
import json
import os
import re
import shlex
import subprocess
import sys

CONTENT_FLAGS = re.compile(
    r"^(-p|-u|-U\d*|--unified(=.*)?|--patch|--follow|--stat.*|--numstat|--shortstat"
    r"|--dirstat.*|--word-diff.*|--patch-with-.*|--cc|-c|-m)$"
)
# Searches walk history until they find N matches, so a count doesn't bound them.
SEARCH_FLAGS = re.compile(r"^(-S.*|-G.*|-L.*|--pickaxe-.*|--find-object(=.*)?)$")
SMALL_LIMIT = 50
GIT_TRUE = ("", "true", "yes", "on", "1")


def segments(command):
    """Split on shell separators; good enough for agent one-liners."""
    return re.split(r"\|\||&&|;|\||\n", command)


def strip_comment(segment):
    """Drop a shell comment: an unquoted # at the start of a word."""
    quote, escaped = None, False
    for i, ch in enumerate(segment):
        if escaped:
            escaped = False
        elif ch == "\\" and quote != "'":
            escaped = True
        elif quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or segment[i - 1].isspace()):
            return segment[:i]
    return segment


def tokens(segment):
    """Shell words of one command."""
    segment = strip_comment(segment)
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


def promisor_remote(repo_args):
    """(remote name, extensions.partialclone is set) for a partial clone, else None."""
    try:
        out = subprocess.run(
            ["git", *repo_args, "config", "--get-regexp",
             r"^(remote\..*\.promisor|remote\..*\.partialclonefilter|extensions\.partialclone)$"],
            capture_output=True, text=True, timeout=3,
        ).stdout
    except Exception:
        return None
    remote, extension = None, False
    for line in out.splitlines():
        key, _, value = line.partition(" ")
        value = value.strip()
        if key == "extensions.partialclone":
            remote, extension = remote or value or "origin", True
        elif key.endswith(".promisor"):
            if value.lower() in GIT_TRUE:
                remote = remote or key[len("remote."):-len(".promisor")]
        else:
            remote = remote or key[len("remote."):-len(".partialclonefilter")]
    return (remote, extension) if remote else None


def limited(args):
    """True if the last commit count given (-3, -n 5, --max-count=10) is small."""
    count = None
    for i, a in enumerate(args):
        m = re.match(r"^-(\d+)$", a) or re.match(r"^-n(\d+)$", a) or re.match(r"^--max-count=(\d+)$", a)
        if m:
            count = int(m.group(1))
        elif a in ("-n", "--max-count") and i + 1 < len(args) and args[i + 1].isdigit():
            count = int(args[i + 1])
    return count is not None and count <= SMALL_LIMIT


def risky_git(toks, cwd):
    """Return (repo label, git args naming the repo, subcommand) for a risky git command."""
    starts = [n for n, t in enumerate(toks) if os.path.basename(t) == "git"]
    if not starts:
        return None
    i = starts[0] + 1
    repo, git_dir = cwd, None
    while i < len(toks) and toks[i].startswith("-"):
        opt = toks[i]
        if opt in ("-C", "--git-dir", "--work-tree", "--namespace", "-c") and i + 1 < len(toks):
            value = os.path.expanduser(toks[i + 1])
            if opt == "-C":
                repo = os.path.join(repo, value)
            elif opt == "--git-dir":
                git_dir = os.path.join(repo, value)
            i += 2
            continue
        if opt.startswith("--git-dir="):
            git_dir = os.path.join(repo, os.path.expanduser(opt.split("=", 1)[1]))
        i += 1
    if i >= len(toks):
        return None
    sub, args = toks[i], toks[i + 1:]
    target = (git_dir, ["--git-dir", git_dir]) if git_dir else (repo, ["-C", repo])
    if sub in ("blame", "annotate"):
        return (*target, sub)
    if sub in ("log", "whatchanged"):
        if any(SEARCH_FLAGS.match(a) for a in args):
            return (*target, sub)
        if any(CONTENT_FLAGS.match(a) for a in args) and not limited(args):
            return (*target, sub)
    return None


def main():
    """Read the PreToolUse event on stdin; print a deny decision if needed."""
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
        partial = promisor_remote(hit[1]) if hit else None
        if partial:
            repo, _, sub = hit
            remote, extension = partial
            unset_extension = "git config --unset extensions.partialclone; " if extension else ""
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
                f"{unset_extension}git -c gc.auto=0 fetch --refetch --no-auto-gc {remote}`."
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
