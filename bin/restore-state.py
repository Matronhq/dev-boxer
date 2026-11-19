#!/usr/bin/env python3
"""Restore only Matron state, never executables or files outside its roots."""
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile


def validate(members, roots):
    seen = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or path == PurePosixPath("."):
            raise ValueError("Backup contains an unsafe path")
        if path in seen:
            raise ValueError("Backup contains a duplicate path")
        seen.add(path)
        if not (member.isfile() or member.isdir()):
            raise ValueError("Backup contains a link or special file")
        if member.name == "manifest.json":
            continue
        if not any(path == root or root in path.parents for root in roots):
            raise ValueError("Backup contains a file outside Matron state")


def checked_manifest(source, roots, username, bundled):
    validate(source.getmembers(), roots)
    manifest = json.load(source.extractfile("manifest.json"))
    if manifest.get("format") != 1 or manifest.get("user") != username or manifest.get("bundled") != bundled:
        raise ValueError("Restore needs the same account and first-box/add-box mode")
    return manifest


def restore(archive, roots, username, bundled, destination=Path("/")):
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        checked_manifest(source, roots, username, bundled)
        with tempfile.TemporaryDirectory(prefix="matron-restore-") as scratch:
            source.extractall(scratch, filter="data")
            # All destination ancestors must be real directories. A worker
            # cannot redirect a privileged restore through its symlinks.
            for member in members:
                if member.name == "manifest.json":
                    continue
                target = destination / member.name
                if any(p.is_symlink() for p in [target, *target.parents]):
                    raise ValueError("Restore destination contains a symlink")
            # A WAL from the replaced database must never be replayed into
            # the restored database. The archive's own WAL, if any, is copied
            # back together with its database below. Services are stopped.
            if any(m.name == "opt/matron-journal/data/matron.db" for m in members):
                for suffix in ("-wal", "-shm"):
                    (destination / ("opt/matron-journal/data/matron.db" + suffix)).unlink(missing_ok=True)
            for member in members:
                if member.name == "manifest.json":
                    continue
                target = destination / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(Path(scratch) / member.name, target)
                os.chmod(target, member.mode & 0o777)


if __name__ == "__main__":
    try:
        check = sys.argv[1] == "--check"
        archive, username, mode, *allowed = sys.argv[2:] if check else sys.argv[1:]
        roots = [PurePosixPath(p.lstrip("/")) for p in allowed]
        if check:
            with tarfile.open(archive, "r:gz") as source:
                checked_manifest(source, roots, username, mode == "bundled")
        else:
            restore(archive, roots, username, mode == "bundled")
    except (ValueError, KeyError, OSError, TypeError, tarfile.TarError) as exc:
        sys.exit(str(exc))
