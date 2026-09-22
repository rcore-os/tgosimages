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
from build_admission import (AdaptiveAdmission, AdmissionMetrics, AdmissionWindow,
                             io_pressure_tier, launch_budget, launch_capacity,
                             prioritize_ready, rebalance_reservations)


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


def cache_option_values(arguments, option):
    return [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value == option]


def add_dependency_cache_inputs(graph):
    """Make cached consumers depend on the declared outputs of cached producers."""
    tasks = {task['id']: task for task in graph['tasks']}
    graph_cwd = Path(graph.get('cwd', os.getcwd())).absolute()
    for task in graph['tasks']:
        arguments = task.get('cache_args')
        if arguments is None:
            continue
        task_cwd = Path(task.get('cwd', graph_cwd)).absolute()
        existing = {
            str((task_cwd / value).absolute()) if not Path(value).is_absolute() else str(Path(value).absolute())
            for value in cache_option_values(arguments, '--input')
        }
        for dependency_name in task['deps']:
            dependency = tasks[dependency_name]
            dependency_arguments = dependency.get('cache_args', [])
            dependency_cwd = Path(dependency.get('cwd', graph_cwd)).absolute()
            for value in cache_option_values(dependency_arguments, '--output'):
                path = Path(value)
                absolute = str(path.absolute() if path.is_absolute() else (dependency_cwd / path).absolute())
                if absolute not in existing:
                    arguments.extend(('--input', absolute))
                    existing.add(absolute)


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
        if task.get('phase', 'run') not in ('prepare', 'build', 'validate', 'compose', 'run'):
            raise ValueError(f'{name}: invalid task phase')
        task.setdefault('deps', [])
        task.setdefault('resources', [])
        task['cpu_min'] = positive(task.get('cpu_min', 1))
        task['cpu_max'] = positive(task.get('cpu_max', jobs))
        task['memory_mb'] = int(task.get('memory_mb', 0))
        if task['cpu_min'] > min(jobs, task['cpu_max']) or task['memory_mb'] < 0:
            raise ValueError(f'{name}: impossible resource request')
        if memory and task['memory_mb'] > memory:
            raise ValueError(f'{name}: memory request exceeds BUILD_MEMORY_MB')
        if not strings(task['deps']) or not strings(task['resources']) or not strings(task.get('locks', [])):
            raise ValueError(f'{name}: dependencies/resources/locks must be strings')
    done = set()
    while len(done) < len(ids):
        ready = {t['id'] for t in tasks if t['id'] not in done and set(t['deps']) <= done}
        if not ready:
            raise ValueError('dependency cycle or unknown dependency')
        done.update(ready)


def execute(graph, log_dir):
    available = positive(subprocess.check_output(['nproc'], text=True).strip())
    jobs = max(1, available * 5 // 8)
    jobs = min(jobs, positive(os.environ.get('TGOS_BUILD_JOB_BUDGET', jobs)))
    explicit_slots = os.environ.get('BUILD_PARALLEL_TASKS')
    admission = AdaptiveAdmission(jobs) if explicit_slots is None else None
    slots = admission.slots if admission else min(jobs, positive(explicit_slots))
    metrics = AdmissionMetrics.system() if admission and os.environ.get('TGOS_CPU_SCOPE_ACTIVE') == '1' else None
    observations = AdmissionWindow() if metrics else None
    memory = int(os.environ.get('BUILD_MEMORY_MB', '0'))
    heartbeat_seconds = positive_seconds(os.environ.get('BUILD_HEARTBEAT_SECONDS', '60'))
    terminate_grace_seconds = positive_seconds(os.environ.get('BUILD_TERMINATE_GRACE_SECONDS', '5'))
    if memory < 0:
        raise ValueError('BUILD_MEMORY_MB must be nonnegative')
    validate(graph, jobs, memory)
    add_dependency_cache_inputs(graph)
    log_dir = Path(log_dir).resolve()
    (log_dir / 'steps').mkdir(parents=True, exist_ok=True)
    (log_dir / 'graph.json').write_text(json.dumps(graph, indent=2) + '\n')
    states = {t['id']: {'state': 'waiting'} for t in graph['tasks']}
    ready_since = {}
    running = {}
    locks = []
    held_task_locks = {}
    last_lock_wait = {}
    last_io_launch = None
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

    def process_group_exists(pgid):
        try:
            os.killpg(pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # A privileged descendant can outlive its unprivileged leader.
            return True

    def terminate_process_groups(processes):
        processes = list(processes)
        for name, process in processes:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError as exc:
                log('WARN', f'{name}: cannot signal complete process group with SIGTERM: {exc}')
        deadline = time.monotonic() + terminate_grace_seconds
        while processes and time.monotonic() < deadline:
            for _, process in processes:
                process.poll()
            processes = [(name, process) for name, process in processes
                         if process_group_exists(process.pid)]
            if processes:
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        for name, process in processes:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError as exc:
                log('ERROR', f'{name}: privileged process survived cancellation: {exc}')
        if processes:
            deadline = time.monotonic() + 1
            while processes and time.monotonic() < deadline:
                for _, process in processes:
                    process.poll()
                processes = [(name, process) for name, process in processes
                             if process_group_exists(process.pid)]
                if processes:
                    time.sleep(0.05)
        for name, process in processes:
            log('ERROR', f'{name}: process group {process.pid} survived SIGKILL; workspace may still be busy')

    def acquire_task_locks(task):
        newly_acquired = []
        for name in sorted(set(task.get('locks', []))):
            if name in held_task_locks:
                continue
            path = Path(name)
            path.parent.mkdir(parents=True, exist_ok=True)
            stream = path.open('a')
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                stream.close()
                for acquired in newly_acquired:
                    fcntl.flock(held_task_locks[acquired], fcntl.LOCK_UN)
                    held_task_locks.pop(acquired).close()
                if time.monotonic() - last_lock_wait.get(name, 0) >= 30:
                    log('INFO', f'WAITING workspace: {path.stem}')
                    last_lock_wait[name] = time.monotonic()
                return False
            held_task_locks[name] = stream
            newly_acquired.append(name)
        return True

    previous = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        cpu_mode = 'cgroup' if os.environ.get('TGOS_CPU_SCOPE_ACTIVE') == '1' else 'static'
        log('INFO', f'START graph: tasks={len(states)} jobs={jobs} slots={slots} cpu={cpu_mode}; logs={log_dir}')
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
        if metrics:
            observations.record(metrics.sample(heartbeat))
        next_admission = heartbeat + 10
        while True:
            failed_name = None
            completed = set()
            for name, (process, stream, task) in list(running.items()):
                code = process.poll()
                if code is None:
                    continue
                if code != 0:
                    # The leader can exit while background compiler children
                    # still own this resource. Stop them before releasing tokens.
                    terminate_process_groups([(name, process)])
                stream.close()
                state = states[name]
                state.update(state='success' if code == 0 else 'failed', status=code,
                             elapsed=round(time.monotonic() - state.pop('started'), 3))
                marker = log_dir / 'steps' / f'{name}.cache-hit'
                step_log = log_dir / 'steps' / f'{name}.log'
                if code == 0 and 'cache_args' in task and marker.exists():
                    state['state'] = 'hit'
                if code == 0:
                    completed.add(name)
                log('SUCCESS' if code == 0 else 'ERROR',
                    f'{"HIT" if state["state"] == "hit" else "FINISHED" if code == 0 else "FAILED"} '
                    f'{name}: status={code} log={step_log} elapsed={state["elapsed"]}s')
                if code:
                    failed_name = failed_name or name
                    with step_log.open(errors='replace') as output:
                        for line in deque(output, maxlen=20):
                            log('ERROR', f'{name}: {line.rstrip()}')
                del running[name]
            if failed_name:
                log('ERROR', f'STOPPING graph after {failed_name} failed: '
                    f'terminating {len(running)} active tasks and cancelling '
                    f'{sum(state["state"] == "waiting" for state in states.values())} waiting tasks')
                break
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
            for name, stream in list(held_task_locks.items()):
                if not any(name in task.get('locks', []) and states[task['id']]['state'] in ('waiting', 'running')
                           for task in graph['tasks']):
                    fcntl.flock(stream, fcntl.LOCK_UN)
                    stream.close()
                    del held_task_locks[name]
            ready = [t for t in graph['tasks'] if states[t['id']]['state'] == 'waiting'
                     and all(states[d]['state'] in ('success', 'hit') for d in t['deps'])]
            now = time.monotonic()
            for task in ready:
                ready_since.setdefault(task['id'], now)
            ready = prioritize_ready(ready, completed=completed, active=running,
                                     ready_since=ready_since, now=now)
            free_cpu = jobs - sum(states[n]['allocation'] for n in running)
            free_memory = memory - sum(t['memory_mb'] for _, _, t in running.values())
            busy = {key for _, _, t in running.values() for key in t['resources']}
            if metrics and now >= next_admission:
                sample = metrics.sample(now)
                observations.record(sample)
                if sample is not None:
                    possible_cpu = jobs - sum(t['cpu_min'] for _, _, t in running.values())
                    eligible = any(not set(t['resources']) & busy and
                                   t['cpu_min'] <= possible_cpu and
                                   (not memory or t['memory_mb'] <= free_memory) for t in ready)
                    previous_slots = slots
                    slots = admission.adjust(cpu_used=sample[0], cpu_some=sample[1],
                                             io_some=sample[2], io_full=sample[3], memory_full=sample[4],
                                             has_ready=eligible, active_count=len(running))
                    if slots != previous_slots:
                        log('INFO', f'ADMISSION graph: slots={previous_slots}->{slots} '
                            f'mode={admission.io_mode} '
                            f'cpu={sample[0]:.1f}/{jobs} cpu_some={sample[1]:.1%} '
                            f'io_some={sample[2]:.1%} io_full={sample[3]:.1%} memory_full={sample[4]:.1%}')
                next_admission = now + 10
            if metrics:
                free_cpu = rebalance_reservations(running, states, jobs=jobs, slots=slots)
            available = slots - len(running)
            sample = observations.last_valid if observations else None
            io_stalled = sample is not None and (admission.io_mode != 'normal' or
                io_pressure_tier(io_some=sample[2], io_full=sample[3]) != 'normal')
            if io_stalled:
                available = launch_capacity(available, io_some=sample[2], io_full=sample[3], cpu_used=sample[0],
                                            jobs=jobs, now=now, last_io_launch=last_io_launch,
                                            constrained=True)
            # Select a wave first, then fairly share currently available CPU tokens.
            wave = []
            for task in ready:
                if len(wave) >= available:
                    break
                if set(task['resources']) & busy or task['cpu_min'] > free_cpu:
                    continue
                if memory and task['memory_mb'] > free_memory:
                    continue
                if not acquire_task_locks(task):
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
            active_count = len(running) + len(wave)
            redundancy = active_count // 4 if active_count >= 4 else 0
            survivors = active_count - redundancy
            for task in wave:
                name = task['id']
                budget = budgets[name]
                if io_stalled:
                    budget = max(task['cpu_min'], launch_budget(
                        budget, jobs=jobs, active_count=active_count,
                        initial_slots=admission.initial, io_some=sample[2], io_full=sample[3],
                        constrained=True))
                tool_budget = budget
                if os.environ.get('TGOS_CPU_SCOPE_ACTIVE') == '1' and not io_stalled:
                    elastic_budget = (jobs + survivors - 1) // survivors
                    tool_budget = max(budget, min(task['cpu_max'], elastic_budget))
                env = dict(os.environ, **graph.get('env', {}), **task.get('env', {}))
                env.update(TGOS_BUILD_JOB_BUDGET=str(tool_budget),
                           CMAKE_BUILD_PARALLEL_LEVEL=str(tool_budget), CARGO_BUILD_JOBS=str(tool_budget),
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
                env['LOG_FILE'] = str(step_log)
                stream = step_log.open('a')
                try:
                    process = subprocess.Popen(command, cwd=task.get('cwd', graph.get('cwd')),
                                               env=env, stdout=stream, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                except OSError as exc:
                    stream.close()
                    states[name].update(state='failed', error=str(exc))
                    log('ERROR', f'FAILED {name}: {exc}')
                    failed_name = name
                    break
                phase = task.get('phase', 'run')
                states[name].update(state='running', phase=phase, jobs=tool_budget, allocation=budget,
                                    started=time.monotonic())
                running[name] = (process, stream, task)
                if io_stalled:
                    last_io_launch = time.monotonic()
                allocation = f' allocation={budget}' if tool_budget != budget else ''
                log('INFO', f'STARTED {name}: jobs={tool_budget}{allocation} log={step_log} phase={phase}')
            if failed_name:
                log('ERROR', f'STOPPING graph after {failed_name} failed to start: '
                    f'terminating {len(running)} active tasks and cancelling '
                    f'{sum(state["state"] == "waiting" for state in states.values())} waiting tasks')
                save()
                break
            save()
            if not running and all(s['state'] != 'waiting' for s in states.values()):
                break
            if time.monotonic() - heartbeat >= heartbeat_seconds:
                log('INFO', f'RUNNING graph: active={len(running)} waiting={sum(s["state"] == "waiting" for s in states.values())} slots={slots}')
                if observations:
                    log('INFO', f'ADMISSION graph: mode={admission.io_mode} '
                        f'{observations.report(slots=slots, jobs=jobs)}')
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
        terminate_process_groups((name, process) for name, (process, _, _) in running.items())
        for name, (process, stream, _) in running.items():
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
        for stream in held_task_locks.values():
            fcntl.flock(stream, fcntl.LOCK_UN)
            stream.close()
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
