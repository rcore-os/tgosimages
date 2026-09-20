#!/usr/bin/env python3
"""Python explicit-input task cache; never cache failures or trust output existence."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
sys.dont_write_bytecode = True
from build_inputs import patch_set, source_state


def log(level, message):
    line = f"[{datetime.datetime.now():%F %T}] [{level}] {message}\n"
    if os.environ.get('LOG_TO_STDERR', '1') == '1':
        sys.stderr.write(line)
    if os.environ.get('LOG_FILE') and (not os.environ.get('LOG_STDIO_CAPTURED') or
                                      os.environ.get('LOG_TO_STDERR', '1') != '1'):
        with open(os.environ['LOG_FILE'], 'a') as stream:
            stream.write(line)


def digest(path, active=None):
    """Include content, names, executable mode and symlink destinations."""
    path = Path(path)
    active = set() if active is None else active
    st = path.lstat()
    identity = (st.st_dev, st.st_ino)
    if identity in active:
        raise ValueError(f'cyclic input/output: {path}')
    active = active | {identity}
    h = hashlib.sha256()
    h.update(str(stat.S_IMODE(st.st_mode)).encode())
    if path.is_symlink():
        h.update(b'link\0' + os.readlink(path).encode())
        h.update(digest(path.resolve(), active).encode())
    elif path.is_file():
        h.update(b'file\0')
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(chunk)
    elif path.is_dir():
        h.update(b'directory\0')
        for child in sorted(path.iterdir()):
            h.update(os.fsencode(child.name) + b'\0' + digest(child, active).encode())
    else:
        raise ValueError(f'not a regular file/directory/symlink: {path}')
    return h.hexdigest()


def manifests(paths):
    return {str(path): digest(path) for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--input', action='append', default=[])
    parser.add_argument('--output', action='append', required=True)
    parser.add_argument('--value', action='append', default=[])
    parser.add_argument('--env', action='append', default=[])
    parser.add_argument('--tool', action='append', default=[])
    parser.add_argument('--patch-dir', action='append', default=[])
    parser.add_argument('--source-ref', nargs=2, action='append', default=[], metavar=('REPO', 'REF'))
    if '--' not in sys.argv:
        parser.error('expected -- followed by an executable command')
    split = sys.argv.index('--')
    args = parser.parse_args(sys.argv[1:split])
    command = sys.argv[split + 1:]
    if not command or not (args.input or args.value or args.source_ref):
        parser.error('declare inputs/values and a command')
    inputs = [Path(p).absolute() for p in args.input]
    outputs = [Path(p).absolute() for p in args.output]
    for source in inputs:
        for output in outputs:
            if source.resolve() == output.resolve() or source.resolve() in output.resolve().parents or output.resolve() in source.resolve().parents:
                parser.error('inputs and outputs must not overlap')
    def tool_identities():
        tools = {}
        for tool in [command[0], *args.tool]:
            resolved = shutil.which(tool)
            if resolved is None:
                raise ValueError(f'tool not found: {tool}')
            tools[tool] = {'path': str(Path(resolved).resolve()), 'sha256': digest(Path(resolved))}
        return tools
    # Callers declare scripts, toolchain/sysroot inputs and dependency outputs.
    def fingerprint():
        data = dict(schema=1, runner=digest(Path(__file__)),
                    helpers=digest(Path(__file__).with_name("build_inputs.py")), cwd=os.getcwd(),
                    inputs=manifests(inputs), sources=[source_state(repo, ref) for repo, ref in args.source_ref], patches=[patch_set(p) for p in args.patch_dir],
                    values=args.value, command=command,
                    tools=tool_identities(), outputs=list(map(str, outputs)),
                    environment={key: os.environ.get(key) for key in args.env})
        return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()

    root = Path(os.environ['BUILD_CACHE_DIR']) / 'tasks'
    root.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256((os.getcwd() + '\0' + args.name).encode()).hexdigest()
    stamp = root / f'{key}.json'
    started = time.monotonic()
    # Keep the lock inode: unlinking it can let concurrent waiters diverge.
    with (root / f'{key}.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = fingerprint()
        reason = 'no successful cache record'
        record = {}
        try:
            record = json.loads(stamp.read_text())
            if not isinstance(record, dict):
                record = {}
        except (OSError, ValueError):
            pass
        enabled = os.environ.get('BUILD_CACHE', '1') != '0'
        if not enabled or os.environ.get('BUILD_REBUILD', '0') == '1':
            reason = 'rebuild requested'
        elif record.get('fingerprint') == before:
            try:
                if record.get('outputs') == manifests(outputs):
                    log('SUCCESS', f'CACHE HIT {args.name}: verified inputs and outputs')
                    if os.environ.get('TGOS_TASK_CACHE_RESULT'):
                        Path(os.environ['TGOS_TASK_CACHE_RESULT']).write_text('hit\n')
                    return 0
                reason = 'output content changed'
            except (OSError, ValueError):
                reason = 'output missing or invalid'
        elif record:
            reason = 'inputs/configuration/toolchain changed'
        log('INFO', f'CACHE MISS {args.name}: {reason}')
        stamp.unlink(missing_ok=True)
        result = subprocess.run(command)
        if result.returncode:
            log('ERROR', f'BUILD {args.name}: status={result.returncode}; cache not published')
            return result.returncode if result.returncode > 0 else 128 - result.returncode
        output_record = manifests(outputs)
        if fingerprint() != before:
            log('WARN', f'BUILD {args.name}: inputs changed during build; cache not published')
            return 0
        if enabled:
            fd, temp = tempfile.mkstemp(dir=root, prefix=f'.{key}.', suffix='.tmp')
            try:
                with os.fdopen(fd, 'w') as stream:
                    json.dump(dict(name=args.name, fingerprint=before, outputs=output_record), stream)
                os.replace(temp, stamp)
            finally:
                Path(temp).unlink(missing_ok=True)
        log('SUCCESS', f'BUILD {args.name}: elapsed={time.monotonic()-started:.2f}s')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        log('ERROR', f'Task cache: {exc}')
        sys.exit(1)
