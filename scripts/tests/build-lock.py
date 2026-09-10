#!/usr/bin/env python3
"""Exercise lock cleanup and force the removed-inode contention race."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

helper = Path(__file__).resolve().parents[1] / 'lib/build-lock.sh'
children = []


def start(body, **extra):
    env = dict(
        os.environ,
        LOCK_HELPER=str(helper),
        BUILD_LOCK_DIR=str(work / '.locks'),
        WORK=str(work),
        **extra,
    )
    process = subprocess.Popen(['bash', '-c', '''
set -euo pipefail
source "$LOCK_HELPER"
trap 'build_lock_release_all' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
''' + body], env=env)
    children.append(process)
    return process


def finished(process, status=0):
    assert process.wait(timeout=10) == status, 'unexpected worker exit status'


def reached(name):
    deadline = time.monotonic() + 10
    while not (work / name).exists():
        assert time.monotonic() < deadline, f'timed out waiting for {name}'
        time.sleep(.01)


def signal(name):
    (work / name).touch()


with tempfile.TemporaryDirectory(prefix='build-lock-test.') as directory:
    work = Path(directory)
    try:
        finished(start('''
build_lock_acquire fd "$WORK/resource.lock"
[[ ! -e $WORK/resource.lock ]]
[[ $(find "$BUILD_LOCK_DIR" -type f -name '*.lock' | wc -l) == 1 ]]
source "$LOCK_HELPER"
(build_lock_release_all)
[[ $(find "$BUILD_LOCK_DIR" -type f -name '*.lock' | wc -l) == 1 ]]
build_lock_release "$fd"
[[ ! -d $BUILD_LOCK_DIR ]]
build_lock_acquire fd "$WORK/resource.lock"
build_lock_acquire second "$WORK/second.lock"
exit 23
'''), 23)
        assert not (work / '.locks').exists()
        print('ok - centralized locks, explicit release, failure cleanup and subshell ownership', flush=True)

        finished(start('''
sha256sum() {
    input=$(cat)
    [[ $input != *second.lock ]] || return 1
    printf '%s' "$input" | command sha256sum
}
build_lock_acquire fd "$WORK/resource.lock"
build_lock_acquire second "$WORK/second.lock"
'''), 1)
        assert not (work / '.locks').exists()
        print('ok - partial acquisition failure releases the first lock', flush=True)

        owner = start('''
build_lock_acquire fd "$WORK/resource.lock"
touch "$WORK/owner-ready"
while [[ ! -e $WORK/owner-go ]]; do sleep .01; done
''')
        reached('owner-ready')
        waiter = start('''
calls=0
flock() {
    calls=$((calls + 1))
    if ((calls == 1)); then
        touch "$WORK/waiter-open"
        while [[ ! -e $WORK/waiter-go ]]; do sleep .01; done
    else
        touch "$WORK/waiter-retry"
    fi
    command flock "$@"
}
build_lock_acquire fd "$WORK/resource.lock"
touch "$WORK/waiter-entered"
''')
        reached('waiter-open')
        signal('owner-go')
        finished(owner)
        assert not (work / '.locks').exists()
        contender = start('''
build_lock_acquire fd "$WORK/resource.lock"
touch "$WORK/contender-ready"
while [[ ! -e $WORK/contender-go ]]; do sleep .01; done
''')
        reached('contender-ready')
        signal('waiter-go')
        reached('waiter-retry')
        assert not (work / 'waiter-entered').exists(), 'waiter entered using an obsolete inode'
        signal('contender-go')
        finished(contender)
        finished(waiter)
        assert (work / 'waiter-entered').exists()
        assert not (work / '.locks').exists()
        print('ok - old-inode waiter retries while a new owner holds the replacement', flush=True)

        for interrupt_at in ('_bl_key=', '_build_lock_held['):
            finished(start('''
set -T
trap 'if [[ $BASH_COMMAND == "$INTERRUPT_AT"* ]]; then trap - DEBUG; kill -TERM "$BASHPID"; fi' DEBUG
build_lock_acquire fd "$WORK/resource.lock"
''', INTERRUPT_AT=interrupt_at), 143)
            assert not (work / '.locks').exists(), 'signal during registration leaked lock'
        print('ok - TERM during partial acquisition cleans up without unset variables', flush=True)

        owner = start('''
build_lock_acquire fd "$WORK/resource.lock"
sleep 3 &
touch "$WORK/inherited-ready"
while [[ ! -e $WORK/inherited-go ]]; do sleep .01; done
''')
        reached('inherited-ready')
        waiter = start('''
flock() {
    [[ $1 != -x ]] || touch "$WORK/inherited-waiter-open"
    command flock "$@"
}
build_lock_acquire fd "$WORK/resource.lock"
''')
        reached('inherited-waiter-open')
        signal('inherited-go')
        finished(owner)
        assert waiter.wait(timeout=1) == 0, 'inherited descriptor kept the waiter blocked'
        assert not (work / '.locks').exists()
        print('ok - inherited child descriptors do not retain a released lock', flush=True)

        owner = start('''
build_lock_acquire fd "$WORK/resource.lock"
touch "$WORK/signal-ready"
while :; do sleep .01; done
''')
        reached('signal-ready')
        owner.terminate()
        finished(owner, 143)
        assert not (work / '.locks').exists()
        print('ok - TERM cleanup preserves the signal exit status', flush=True)

        workers = [start('''
for ((i=0; i<20; i++)); do
    build_lock_acquire fd "$WORK/resource.lock"
    mkdir "$WORK/critical"
    printf 'entry\n' >> "$WORK/entries"
    rmdir "$WORK/critical"
    build_lock_release "$fd"
done
''') for _ in range(8)]
        for worker in workers:
            finished(worker)
        assert len((work / 'entries').read_text().splitlines()) == 160
        assert not (work / '.locks').exists()
        print('ok - 160 contended critical sections stay exclusive and leave no locks', flush=True)
    finally:
        for process in children:
            if process.poll() is None:
                process.kill()
                process.wait()
