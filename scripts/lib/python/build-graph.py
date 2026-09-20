#!/usr/bin/env python3
"""Dependency scheduler. Commands are argv arrays, never serialized shell functions."""
import argparse
from collections import deque
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


PYTHON_LIB = Path(__file__).resolve().parent
SHELL_LIB = PYTHON_LIB.parent


def positive(value):
    number = int(value)
    if number < 1:
        raise ValueError('resource limits must be positive integers')
    return number


def positive_seconds(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise ValueError('heartbeat interval must be a positive number')
    return number


def last_progress_line(path, read_bytes=8192, display_chars=300):
    """Read one bounded, printable progress line without loading a growing log."""
    try:
        with path.open('rb') as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - read_bytes))
            data = stream.read()
    except OSError:
        return '(log unavailable)'
    for raw_line in reversed(data.splitlines()):
        line = raw_line.decode(errors='replace').strip()
        if line:
            line = ''.join(character if character.isprintable() or character == '\t' else '?' for character in line)
            return line if len(line) <= display_chars else f'{line[:display_chars - 3]}...'
    return '(no output yet)'


def validate(graph, jobs, memory):
    def strings(value):
        return isinstance(value, list) and all(isinstance(x, str) and '\0' not in x for x in value)

    def environment(value):
        return isinstance(value, dict) and all(isinstance(k, str) and k and '=' not in k and '\0' not in k
                                               and isinstance(v, str) and '\0' not in v for k, v in value.items())

    if not environment(graph.get('env', {})) or not strings(graph.get('locks', [])):
        raise ValueError('invalid graph environment or locks')
    if 'cwd' in graph and not isinstance(graph['cwd'], str):
        raise ValueError('graph cwd must be a string')
    tasks = graph['tasks']
    ids = set()
    for task in tasks:
        name = task['id']
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) or name in ids:
            raise ValueError(f'invalid or duplicate task ID: {name}')
        ids.add(name)
        command = task['command']
        if not strings(command) or not command or not command[0]:
            raise ValueError(f'{name}: command must be an argv array')
        if not environment(task.get('env', {})) or ('cwd' in task and not isinstance(task['cwd'], str)):
            raise ValueError(f'{name}: invalid environment or cwd')
        if 'cache_args' in task and not strings(task['cache_args']):
            raise ValueError(f'{name}: cache_args must be an argv array')
        task.setdefault('deps', [])
        task.setdefault('resources', [])
        task['cpu_min'] = positive(task.get('cpu_min', 1))
        task['cpu_max'] = positive(task.get('cpu_max', jobs))
        task['memory_mb'] = int(task.get('memory_mb', 0))
        if task['cpu_min'] > min(jobs, task['cpu_max']) or task['memory_mb'] < 0:
            raise ValueError(f'{name}: impossible resource request')
        if memory and task['memory_mb'] > memory:
            raise ValueError(f'{name}: memory request exceeds BUILD_MEMORY_MB')
        if not strings(task['deps']) or not strings(task['resources']):
            raise ValueError(f'{name}: dependencies/resources must be strings')
    done = set()
    while len(done) < len(ids):
        ready = {t['id'] for t in tasks if t['id'] not in done and set(t['deps']) <= done}
        if not ready:
            raise ValueError('dependency cycle or unknown dependency')
        done.update(ready)


def execute(graph, log_dir):
    jobs = positive(os.environ.get('BUILD_JOBS') or '32')
    jobs = min(jobs, positive(os.environ.get('TGOS_BUILD_JOB_BUDGET', jobs)))
    slots = min(jobs, positive(os.environ.get('BUILD_PARALLEL_TASKS', jobs)))
    memory = int(os.environ.get('BUILD_MEMORY_MB', '0'))
    heartbeat_seconds = positive_seconds(os.environ.get('BUILD_HEARTBEAT_SECONDS', '60'))
    if memory < 0:
        raise ValueError('BUILD_MEMORY_MB must be nonnegative')
    validate(graph, jobs, memory)
    log_dir = Path(log_dir).resolve()
    (log_dir / 'steps').mkdir(parents=True, exist_ok=True)
    (log_dir / 'graph.json').write_text(json.dumps(graph, indent=2) + '\n')
    states = {t['id']: {'state': 'waiting'} for t in graph['tasks']}
    running = {}
    locks = []
    renderer = None
    mode = os.environ.get('LOG_COLOR', 'auto')
    color = not os.environ.get('LOG_STDIO_CAPTURED') and (mode == 'always' or
            (mode == 'auto' and sys.stdout.isatty() and 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb'))
    if color:
        renderer = subprocess.Popen(['awk', '-f', str(SHELL_LIB / 'log-color.awk')],
                                    stdin=subprocess.PIPE, text=True)

    def log(level, message):
        line = f'[{datetime.datetime.now():%F %T}] [{level}] {message}\n'
        with (log_dir / 'summary.log').open('a') as stream:
            stream.write(line)
        stream = renderer.stdin if renderer else sys.stdout
        stream.write(line)
        stream.flush()

    def save():
        temp = log_dir / 'state.json.tmp'
        temp.write_text(json.dumps(states, indent=2) + '\n')
        temp.replace(log_dir / 'state.json')

    def interrupted(signum, _frame):
        raise InterruptedError(f'scheduler interrupted by signal {signum}')

    previous = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        log('INFO', f'START graph: tasks={len(states)} jobs={jobs} slots={slots}; logs={log_dir}')
        save()
        # Persistent workspace locks cover preparation through composition. Sorted
        # acquisition prevents deadlock between overlapping independent invocations.
        for path in sorted(set(graph.get('locks', []))):
            path = Path(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            lock = path.open('a')
            locks.append(lock)
            last = 0
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() - last >= 30:
                        log('INFO', f'WAITING workspace: {path.stem}')
                        last = time.monotonic()
                    time.sleep(0.1)
        heartbeat = time.monotonic()
        while True:
            for name, (process, stream, task) in list(running.items()):
                code = process.poll()
                if code is None:
                    continue
                if code != 0:
                    # The leader can exit while background compiler children
                    # still own this resource. Stop them before releasing tokens.
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                        time.sleep(0.2)
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                stream.close()
                state = states[name]
                state.update(state='success' if code == 0 else 'failed', status=code,
                             elapsed=round(time.monotonic() - state.pop('started'), 3))
                marker = log_dir / 'steps' / f'{name}.cache-hit'
                step_log = log_dir / 'steps' / f'{name}.log'
                if code == 0 and 'cache_args' in task and marker.exists():
                    state['state'] = 'hit'
                log('SUCCESS' if code == 0 else 'ERROR',
                    f'{"HIT" if state["state"] == "hit" else "FINISHED" if code == 0 else "FAILED"} '
                    f'{name}: status={code} log={step_log} elapsed={state["elapsed"]}s')
                if code:
                    with step_log.open(errors='replace') as output:
                        for line in deque(output, maxlen=20):
                            log('ERROR', f'{name}: {line.rstrip()}')
                del running[name]
            # Repeat propagation so a blocked chain is resolved in this iteration.
            changed = True
            while changed:
                changed = False
                for task in graph['tasks']:
                    name = task['id']
                    if states[name]['state'] == 'waiting' and any(states[d]['state'] in ('failed', 'blocked', 'cancelled') for d in task['deps']):
                        states[name]['state'] = 'blocked'
                        log('WARN', f'BLOCKED {name}: dependency failed')
                        changed = True
            ready = [t for t in graph['tasks'] if states[t['id']]['state'] == 'waiting'
                     and all(states[d]['state'] in ('success', 'hit') for d in t['deps'])]
            free_cpu = jobs - sum(states[n]['jobs'] for n in running)
            free_memory = memory - sum(t['memory_mb'] for _, _, t in running.values())
            busy = {key for _, _, t in running.values() for key in t['resources']}
            available = slots - len(running)
            # Select a wave first, then fairly share currently available CPU tokens.
            wave = []
            for task in ready:
                if len(wave) >= available:
                    break
                if set(task['resources']) & busy or task['cpu_min'] > free_cpu:
                    continue
                if memory and task['memory_mb'] > free_memory:
                    continue
                wave.append(task)
                free_cpu -= task['cpu_min']
                free_memory -= task['memory_mb']
                busy.update(task['resources'])
            budgets = {t['id']: t['cpu_min'] for t in wave}
            while free_cpu:
                expandable = [t for t in wave if budgets[t['id']] < t['cpu_max']]
                if not expandable:
                    break
                for task in expandable:
                    if not free_cpu:
                        break
                    budgets[task['id']] += 1
                    free_cpu -= 1
            for task in wave:
                name = task['id']
                budget = budgets[name]
                env = dict(os.environ, **graph.get('env', {}), **task.get('env', {}))
                env.update(TGOS_BUILD_JOB_BUDGET=str(budget), BUILD_JOBS=str(budget),
                           CMAKE_BUILD_PARALLEL_LEVEL=str(budget), CARGO_BUILD_JOBS=str(budget),
                           LOG_STDIO_CAPTURED='1', LOG_TO_STDERR='1', LOG_CREATE_DEFAULT_FILE='0',
                           LOG_COLOR='never', BUILD_PARALLEL_TASKS='1')
                env.pop('LOG_FILE', None)
                env.pop('TGOS_TASK_CACHE_RESULT', None)
                command = task['command']
                if 'cache_args' in task:
                    marker = log_dir / 'steps' / f'{name}.cache-hit'
                    marker.unlink(missing_ok=True)
                    env['TGOS_TASK_CACHE_RESULT'] = str(marker)
                    command = [sys.executable, str(PYTHON_LIB / 'build-task.py'),
                               name, *task['cache_args'], '--', *command]
                step_log = log_dir / 'steps' / f'{name}.log'
                stream = step_log.open('w')
                try:
                    process = subprocess.Popen(command, cwd=task.get('cwd', graph.get('cwd')),
                                               env=env, stdout=stream, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                except OSError as exc:
                    stream.close()
                    states[name].update(state='failed', error=str(exc))
                    log('ERROR', f'FAILED {name}: {exc}')
                    continue
                states[name].update(state='running', jobs=budget, started=time.monotonic())
                running[name] = (process, stream, task)
                log('INFO', f'STARTED {name}: jobs={budget} log={step_log}')
            save()
            if not running and all(s['state'] != 'waiting' for s in states.values()):
                break
            if time.monotonic() - heartbeat >= heartbeat_seconds:
                log('INFO', f'RUNNING graph: active={len(running)} waiting={sum(s["state"] == "waiting" for s in states.values())}')
                now = time.monotonic()
                for name in running:
                    state = states[name]
                    step_log = log_dir / 'steps' / f'{name}.log'
                    log('INFO', f'RUNNING {name}: elapsed={now - state["started"]:.1f}s jobs={state["jobs"]} '
                        f'log={step_log} last={last_progress_line(step_log)}')
                dependency_wait = 0
                resource_wait = 0
                for task in graph['tasks']:
                    if states[task['id']]['state'] != 'waiting':
                        continue
                    if all(states[dependency]['state'] in ('success', 'hit') for dependency in task['deps']):
                        resource_wait += 1
                    else:
                        dependency_wait += 1
                log('INFO', f'WAITING graph: dependencies={dependency_wait} resources={resource_wait}')
                heartbeat = time.monotonic()
            time.sleep(0.05)
        failed = any(s['state'] not in ('success', 'hit') for s in states.values())
        log('ERROR' if failed else 'SUCCESS', f'COMPLETE graph: {"failed" if failed else "all tasks finished successfully"}')
        return int(failed)
    finally:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        # Terminate complete process groups before releasing mutable workspaces.
        for process, _, _ in running.values():
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        if running:
            time.sleep(0.2)
        for name, (process, stream, _) in running.items():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            stream.close()
            states[name]['state'] = 'cancelled'
        for state in states.values():
            if state['state'] == 'waiting':
                state['state'] = 'cancelled'
        save()
        for lock in reversed(locks):
            fcntl.flock(lock, fcntl.LOCK_UN)
            lock.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if renderer:
            renderer.stdin.close()
            renderer.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--log-dir', type=Path)
    args = parser.parse_args()
    log_dir = args.log_dir or tempfile.mkdtemp(prefix='build-graph-')
    return execute(json.loads(args.manifest.read_text()), log_dir)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'Build graph: {exc}', file=sys.stderr)
        sys.exit(1)
