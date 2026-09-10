#!/usr/bin/env python3
"""Fingerprint checked-out BusyBox inputs without git metadata/build products."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys

source, patches = map(Path, sys.argv[1:])
digest = hashlib.sha256()


def add(root, name):
    path = root / os.fsdecode(name)
    digest.update(name + b"\0")
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        digest.update(b"missing\0")
        return
    digest.update(str(stat.S_IMODE(mode)).encode() + b"\0")
    if stat.S_ISLNK(mode):
        digest.update(b"link\0" + os.fsencode(os.readlink(path)))
    elif stat.S_ISREG(mode):
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    else:
        raise ValueError(f"Unsupported BusyBox source input: {path}")
    digest.update(b"\0")


# Tracked inputs always participate, even if matched by an ignore rule. Untracked
# source files participate too; ignored object files and git internals do not.
names = subprocess.check_output(
    ["git", "-C", str(source), "ls-files", "-c", "-o", "--exclude-standard", "-z"]
).split(b"\0")
for name in sorted(set(names) - {b""}):
    if name.split(b"/", 1)[0] != b".patch_stamps":
        add(source, name)
for pattern in ("*.patch", "*.diff"):
    for path in sorted(patches.glob(pattern)):
        add(patches, os.fsencode(path.name))
print(digest.hexdigest())
