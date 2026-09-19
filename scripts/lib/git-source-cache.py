#!/usr/bin/env python3
"""Share downloaded Git objects; each destination is an independent checkout."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


def git(*args, capture=False):
    if capture:
        return subprocess.check_output(['git', *map(str, args)], text=True).strip()
    subprocess.run(['git', *map(str, args)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('clone', 'ref'))
    parser.add_argument('repo')
    parser.add_argument('value')
    args = parser.parse_args()
    repo = Path(args.repo).absolute()
    url = args.value if args.operation == 'clone' else git('-C', repo, 'remote', 'get-url', 'origin', capture=True)
    root = Path(os.environ['BUILD_SOURCE_CACHE_DIR']).absolute()
    root.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()
    cache = root / f'{key}.git'
    with (root / f'{key}.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not cache.exists():
            with tempfile.TemporaryDirectory(prefix=f'.{key}.', dir=root) as stage:
                candidate = Path(stage) / 'source.git'
                git('clone', '--bare', '--depth=1', url, candidate)
                # Avoid automatic object pruning while independent tasks fetch.
                git('-C', candidate, 'config', 'gc.auto', '0')
                candidate.rename(cache)
        elif args.operation == 'clone':
            # A new workspace should see today's default branch, not the one
            # used when the download cache was first created. Object transfer
            # still happens only once for each upstream update.
            git('-C', cache, 'fetch', '--quiet', '--depth=1', '--no-tags', 'origin', 'HEAD')
            tip = git('-C', cache, 'rev-parse', 'FETCH_HEAD^{commit}', capture=True)
            git('-C', cache, 'update-ref', 'HEAD', tip)
        if args.operation == 'clone':
            # Fetch a local pack instead of using alternates/hardlinks. Deleting
            # a download cache must never break an existing workspace repository.
            git('clone', '--no-local', '--depth=1', cache.as_uri(), repo)
            git('-C', repo, 'remote', 'set-url', 'origin', url)
        else:
            ref_key = hashlib.sha256(args.value.encode()).hexdigest()
            cached_ref = f'refs/tgos-cache/{ref_key}'
            # Cache explicit immutable commits, but refresh named refs when the
            # caller explicitly asks to fetch them.
            immutable = len(args.value) == 40 and all(c in '0123456789abcdefABCDEF' for c in args.value)
            found = subprocess.run(['git', '-C', str(cache), 'cat-file', '-e', args.value + '^{commit}'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if not immutable or not found:
                git('-C', cache, 'fetch', '--quiet', '--depth=1', '--no-tags', 'origin', args.value)
                resolved = git('-C', cache, 'rev-parse', 'FETCH_HEAD^{commit}', capture=True)
            else:
                resolved = git('-C', cache, 'rev-parse', args.value + '^{commit}', capture=True)
            git('-C', cache, 'update-ref', cached_ref, resolved)
            git('-C', repo, 'fetch', '--quiet', '--depth=1', '--no-tags', cache.as_uri(), cached_ref)
            print(git('-C', repo, 'rev-parse', 'FETCH_HEAD^{commit}', capture=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f'Source cache: {exc}')
