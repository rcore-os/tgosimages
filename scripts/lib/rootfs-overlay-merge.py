#!/usr/bin/env python3
"""Merge independently built rootfs-test plugin trees without hiding collisions."""
import argparse
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


def kind(path):
    mode = path.lstat().st_mode
    if stat.S_ISDIR(mode):
        return 'directory'
    if stat.S_ISREG(mode):
        return 'file'
    if stat.S_ISLNK(mode):
        return 'symlink'
    raise ValueError(f'unsupported filesystem object: {path}')


def inventory(inputs):
    seen = {}
    for source in inputs:
        if not source.is_dir() or source.is_symlink():
            raise ValueError(f'plugin output is not a directory: {source}')
        for path in sorted(source.rglob('*')):
            relative = path.relative_to(source)
            entry_kind = kind(path)
            for parent in relative.parents:
                if str(parent) != '.' and seen.get(str(parent)) not in (None, 'directory'):
                    raise ValueError(f'overlay ancestor collision: {parent} blocks {relative}')
            previous = seen.get(str(relative))
            if previous is not None and not (previous == entry_kind == 'directory'):
                raise ValueError(f'overlay collision: {relative}')
            seen[str(relative)] = entry_kind


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('inputs', nargs='*', type=Path)
    args = parser.parse_args()
    inventory(args.inputs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f'.{args.output.name}.', dir=args.output.parent))
    backup = args.output.with_name(f'.{args.output.name}.old.{os.getpid()}')
    try:
        for source in args.inputs:
            shutil.copytree(source, temporary, dirs_exist_ok=True, symlinks=True)
        if args.output.exists() or args.output.is_symlink():
            if backup.exists() or backup.is_symlink():
                raise ValueError(f'backup path already exists: {backup}')
            args.output.rename(backup)
        temporary.rename(args.output)
        if backup.exists() or backup.is_symlink():
            shutil.rmtree(backup) if backup.is_dir() and not backup.is_symlink() else backup.unlink()
    except Exception:
        if not (args.output.exists() or args.output.is_symlink()) and (backup.exists() or backup.is_symlink()):
            backup.rename(args.output)
        raise
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        print(f'rootfs overlay merge: {exc}', file=sys.stderr)
        sys.exit(1)
