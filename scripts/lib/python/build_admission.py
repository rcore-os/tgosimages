"""Adaptive admission of new graph nodes; running workers are never resized."""
import math
from pathlib import Path


def prioritize_ready(ready, *, completed, active, ready_since, now):
    """Prefer related work, but let tasks waiting a minute take precedence."""
    def group(name):
        prefix, separator, _ = name.partition('.')
        return prefix if separator else None

    related = {group(name) for name in (*active, *completed)}

    def priority(task):
        name = task['id']
        waiting = now - ready_since[name]
        aged = waiting >= 60
        task_group = group(name)
        same_group = task_group is not None and task_group in related
        return (not aged, ready_since[name] if aged else 0,
                not bool(completed.intersection(task['deps'])), not same_group)

    return sorted(ready, key=priority)


def rebalance_reservations(running, states, *, jobs, slots):
    """Reclaim launch reservations without changing running tools' -j."""
    target = max(1, jobs // slots)
    for name, (_, _, task) in running.items():
        states[name]['allocation'] = max(task['cpu_min'],
                                         min(states[name]['allocation'], target))
    return jobs - sum(states[name]['allocation'] for name in running)


def io_pressure_tier(*, io_some, io_full):
    if io_full >= 0.70:
        return 'severe'
    if io_full >= 0.50 or io_some >= 0.70:
        return 'hold'
    if io_full >= 0.20 or io_some >= 0.50:
        return 'probe'
    return 'normal'


def launch_capacity(available, *, io_full, io_some=0, cpu_used, jobs, now, last_io_launch,
                    constrained=False):
    """Pace launches during IO stalls without shrinking already-running work."""
    available = max(0, available)
    if not constrained and io_pressure_tier(io_some=io_some, io_full=io_full) == 'normal':
        return available
    if cpu_used >= 0.8 * jobs or (last_io_launch is not None and now - last_io_launch < 10):
        return 0
    return min(available, 1)


def launch_budget(budget, *, jobs, active_count, initial_slots, io_full, io_some=0,
                  constrained=False):
    """Keep a single IO-stall probe from inheriting all unused CPU tokens."""
    if not constrained and io_pressure_tier(io_some=io_some, io_full=io_full) == 'normal':
        return budget
    share = 4 * max(initial_slots, active_count)
    return min(budget, (jobs * 5 + share - 1) // share)


class AdmissionWindow:
    """Summarize scheduler samples between progress heartbeats."""
    def __init__(self):
        self.latest = None
        self.last_valid = None
        self.peaks = None
        self.count = 0
        self.had_sample = False

    def record(self, sample):
        self.latest = sample
        if sample is None:
            return
        self.last_valid = sample
        self.had_sample = True
        self.count += 1
        self.peaks = sample if self.peaks is None else tuple(max(a, b) for a, b in zip(self.peaks, sample))

    def report(self, *, slots, jobs):
        if self.latest is None:
            report = f'slots={slots} metrics={"unavailable" if self.had_sample else "warming-up"}'
            self.peaks = None
            self.count = 0
            return report
        cpu, cpu_some, io_some, io_full, memory_full = self.latest
        _, peak_cpu_some, peak_io_some, peak_io_full, peak_memory_full = self.peaks or self.latest
        report = (f'slots={slots} cpu={cpu:.1f}/{jobs} '
                  f'cpu_some={cpu_some:.1%} peak_cpu_some={peak_cpu_some:.1%} '
                  f'io_some={io_some:.1%} peak_io_some={peak_io_some:.1%} '
                  f'io_full={io_full:.1%} peak_io_full={peak_io_full:.1%} '
                  f'memory_full={memory_full:.1%} peak_memory_full={peak_memory_full:.1%} '
                  f'samples={self.count}')
        self.peaks = None
        self.count = 0
        return report


class AdaptiveAdmission:
    def __init__(self, jobs):
        self.jobs = jobs
        self.slots = max(1, min(jobs, math.isqrt(jobs - 1) + 1))
        self.initial = self.slots
        self.minimum = max(1, self.slots // 2)
        self.limit = min(jobs, 2 * self.slots)
        self.io_mode = 'normal'
        self.io_severe_samples = 0
        self.io_recovery_samples = 0

    def adjust(self, *, cpu_used, cpu_some, io_full, memory_full, has_ready, active_count=None,
               io_some=0):
        if any(value is None for value in (cpu_used, cpu_some, io_full, memory_full)) or not has_ready:
            return self.slots
        tier = io_pressure_tier(io_some=io_some, io_full=io_full)
        if max(cpu_some, memory_full) >= 0.10:
            self.slots = max(self.minimum, self.slots * 3 // 4)
            self.io_severe_samples = 0
            self.io_recovery_samples = 0
        elif tier == 'severe':
            self.io_mode = tier
            self.io_recovery_samples = 0
            self.io_severe_samples += 1
            if self.io_severe_samples >= 3:
                self.slots = max(self.minimum, self.slots - 1)
                self.io_severe_samples = 0
        elif tier == 'hold':
            self.io_mode = tier
            self.io_severe_samples = 0
            self.io_recovery_samples = 0
        elif tier == 'probe':
            self.io_mode = tier
            self.io_severe_samples = 0
            self.io_recovery_samples = 0
            if cpu_used < 0.8 * self.jobs and (active_count is None or active_count >= self.slots):
                self.slots = min(self.limit, self.slots + 1)
        else:
            self.io_severe_samples = 0
            if self.io_mode != 'normal':
                self.io_mode = 'recovering'
                self.io_recovery_samples += 1
                if self.io_recovery_samples < 3:
                    return self.slots
            self.io_mode = 'normal'
            self.io_recovery_samples = 0
            if cpu_used < 0.8 * self.jobs and max(cpu_some, memory_full) < 0.05:
                self.slots = min(self.limit, (self.slots * 3 + 1) // 2)
        return self.slots

class AdmissionMetrics:
    def __init__(self, cpu_stat, cpu_pressure, io_pressure, memory_pressure):
        self.cpu_stat = Path(cpu_stat)
        self.cpu_pressure = Path(cpu_pressure)
        self.io_pressure = Path(io_pressure)
        self.memory_pressure = Path(memory_pressure)
        self.previous = None

    @classmethod
    def system(cls):
        try:
            line = next(line for line in Path('/proc/self/cgroup').read_text().splitlines()
                        if line.startswith('0::'))
            group = line[3:].lstrip('/')
            cpu_stat = Path('/sys/fs/cgroup') / group / 'cpu.stat'
            pressure_files = [cpu_stat.with_name(name) for name in
                              ('cpu.pressure', 'io.pressure', 'memory.pressure')]
            if not cpu_stat.is_file() or not all(path.is_file() for path in pressure_files):
                return None
            return cls(cpu_stat, *pressure_files)
        except (OSError, StopIteration):
            return None

    def sample(self, now):
        try:
            usage = next(int(line.split()[1]) for line in self.cpu_stat.read_text().splitlines()
                         if line.startswith('usage_usec '))
            def pressure(path, kind):
                line = next(line for line in path.read_text().splitlines() if line.startswith(kind + ' '))
                return float(next(field.split('=', 1)[1] for field in line.split()
                                  if field.startswith('avg10='))) / 100
            cpu_some = pressure(self.cpu_pressure, 'some')
            io_some = pressure(self.io_pressure, 'some')
            io_full = pressure(self.io_pressure, 'full')
            memory_full = pressure(self.memory_pressure, 'full')
        except (OSError, ValueError, StopIteration):
            self.previous = None
            return None
        previous = self.previous
        self.previous = (now, usage)
        if previous is None or now <= previous[0] or usage < previous[1]:
            return None
        return ((usage - previous[1]) / 1_000_000 / (now - previous[0]),
                cpu_some, io_some, io_full, memory_full)
