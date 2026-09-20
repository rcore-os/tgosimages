#!/usr/bin/env python3
"""Check dependency/resource contracts with real subprocesses and task caching."""
import json
import contextlib
import fcntl
import importlib.util
import io
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lib/python'))
from build_pipeline import BuildPipeline
from build_admission import AdaptiveAdmission, AdmissionMetrics, prioritize_ready
import build_admission

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / 'scripts/lib/python'


class GraphTests(unittest.TestCase):
    def test_ready_affinity_prefers_active_group_but_ages_out(self):
        ready = [dict(id='qemu-riscv64.other', deps=[]),
                 dict(id='qemu-aarch64.peer', deps=[])]
        active = {'qemu-aarch64.linux': None}
        recent = dict.fromkeys((task['id'] for task in ready), 119)
        ordered = prioritize_ready(ready, active=active, completed=set(),
                                   ready_since=recent, now=120)
        self.assertEqual(ordered[0]['id'], 'qemu-aarch64.peer')
        recent['qemu-riscv64.other'] = 0
        ordered = prioritize_ready(ready, active=active, completed=set(),
                                   ready_since=recent, now=120)
        self.assertEqual(ordered[0]['id'], 'qemu-riscv64.other')

    def test_adaptive_admission_scales_only_new_launches(self):
        admission = AdaptiveAdmission(50)
        initial = admission.slots
        admission.adjust(cpu_used=12, cpu_some=0, io_full=0, memory_full=0, has_ready=True)
        expanded = admission.slots
        self.assertGreater(expanded, initial)
        admission.adjust(cpu_used=48, cpu_some=0, io_full=0, memory_full=0, has_ready=True)
        self.assertEqual(admission.slots, expanded)
        admission.adjust(cpu_used=10, cpu_some=0.12, io_full=0, memory_full=0, has_ready=True)
        after_cpu_pressure = admission.slots
        self.assertLess(after_cpu_pressure, expanded)
        admission.adjust(cpu_used=10, cpu_some=0, io_full=0, memory_full=0.12, has_ready=True)
        after_memory_pressure = admission.slots
        self.assertLess(after_memory_pressure, after_cpu_pressure)
        admission.adjust(cpu_used=10, cpu_some=0, io_full=0, memory_full=0, has_ready=False)
        self.assertEqual(admission.slots, after_memory_pressure)
        for _ in range(20):
            admission.adjust(cpu_used=10, cpu_some=0, io_full=0.33, memory_full=0,
                             has_ready=True, active_count=admission.slots)
        self.assertEqual(admission.slots, admission.limit)

    def test_adaptive_admission_keeps_last_good_limit_when_metrics_are_unavailable(self):
        admission = AdaptiveAdmission(50)
        admission.adjust(cpu_used=5, cpu_some=0, io_full=0, memory_full=0, has_ready=True)
        before = admission.slots
        admission.adjust(cpu_used=None, cpu_some=0, io_full=0, memory_full=0, has_ready=True)
        self.assertEqual(admission.slots, before)

    def test_io_pressure_uses_probe_hold_and_gradual_shrink_tiers(self):
        admission = AdaptiveAdmission(50)
        initial = admission.slots
        probed = admission.adjust(cpu_used=1.5, cpu_some=0, io_full=0.33,
                                  memory_full=0, has_ready=True, active_count=initial)
        self.assertEqual(probed, initial + 1)
        held = admission.adjust(cpu_used=1.2, cpu_some=0, io_full=0.51,
                                memory_full=0, has_ready=True, active_count=probed)
        self.assertEqual(held, probed)
        for _ in range(2):
            self.assertEqual(admission.adjust(cpu_used=1.2, cpu_some=0, io_full=0.71,
                                              memory_full=0, has_ready=True,
                                              active_count=held), held)
        self.assertEqual(admission.adjust(cpu_used=1.2, cpu_some=0, io_full=0.71,
                                          memory_full=0, has_ready=True,
                                          active_count=held), held - 1)

    def test_io_recovery_requires_three_samples_before_fast_expansion(self):
        admission = AdaptiveAdmission(50)
        admission.adjust(cpu_used=1, cpu_some=0, io_full=0.55,
                         memory_full=0, has_ready=True, active_count=admission.slots)
        held = admission.slots
        for _ in range(2):
            self.assertEqual(admission.adjust(cpu_used=1, cpu_some=0, io_full=0.10,
                                              memory_full=0, has_ready=True,
                                              active_count=held), held)
        self.assertGreater(admission.adjust(cpu_used=1, cpu_some=0, io_full=0.10,
                                            memory_full=0, has_ready=True,
                                            active_count=held), held)

    def test_io_some_only_affects_admission_at_higher_thresholds(self):
        admission = AdaptiveAdmission(50)
        initial = admission.slots
        for _ in range(3):
            admission.adjust(cpu_used=1, cpu_some=0, io_some=0.49, io_full=0.01,
                             memory_full=0, has_ready=True, active_count=admission.slots)
        self.assertGreater(admission.slots, initial)
        held = admission.slots
        admission.adjust(cpu_used=1, cpu_some=0, io_some=0.71, io_full=0.01,
                         memory_full=0, has_ready=True, active_count=held)
        self.assertEqual(admission.slots, held)

    def test_io_stall_limits_new_launch_rate_and_initial_worker_budget(self):
        self.assertEqual(build_admission.launch_capacity(4, io_full=0.51, cpu_used=1.2,
                                                        jobs=50, now=100, last_io_launch=None), 1)
        self.assertEqual(build_admission.launch_capacity(4, io_full=0.51, cpu_used=1.2,
                                                        jobs=50, now=105, last_io_launch=100), 0)
        self.assertEqual(build_admission.launch_capacity(4, io_full=0.51, cpu_used=1.2,
                                                        jobs=50, now=110, last_io_launch=100), 1)
        self.assertEqual(build_admission.launch_capacity(4, io_full=0.01, cpu_used=1.2,
                                                        jobs=50, now=105, last_io_launch=100), 4)
        self.assertEqual(build_admission.launch_capacity(4, io_full=0.10, cpu_used=1.2,
                                                        jobs=50, now=110, last_io_launch=100,
                                                        constrained=True), 1)
        self.assertEqual(build_admission.launch_capacity(-2, io_full=0.51, cpu_used=1.2,
                                                        jobs=50, now=110, last_io_launch=100), 0)
        self.assertLess(build_admission.launch_budget(26, jobs=50, active_count=5,
                                                       initial_slots=8, io_full=0.51), 26)
        self.assertEqual(build_admission.launch_budget(26, jobs=50, active_count=5,
                                                        initial_slots=8, io_full=0.01), 26)
        self.assertLess(build_admission.launch_budget(26, jobs=50, active_count=5,
                                                       initial_slots=8, io_full=0.10,
                                                       constrained=True), 26)

    def test_io_stall_does_not_expand_unused_slots(self):
        admission = AdaptiveAdmission(50)
        initial = admission.slots
        admission.adjust(cpu_used=1.2, cpu_some=0, io_full=0.51,
                         memory_full=0, has_ready=True, active_count=4)
        self.assertEqual(admission.slots, initial)

    def test_io_some_keeps_launch_paced_when_a_cpu_worker_makes_io_full_drop(self):
        admission = AdaptiveAdmission(50)
        initial = admission.slots
        self.assertEqual(admission.adjust(cpu_used=2, cpu_some=0, io_some=0.51,
                                          io_full=0.01, memory_full=0, has_ready=True,
                                          active_count=initial), initial + 1)
        self.assertEqual(build_admission.launch_capacity(4, io_some=0.51, io_full=0.01,
                                                        cpu_used=2, jobs=50, now=100,
                                                        last_io_launch=None), 1)

    def test_admission_metrics_measure_cgroup_cpu_and_pressure(self):
        cpu = self.root / 'cpu.stat'
        cpu_pressure = self.root / 'cpu.pressure'
        io = self.root / 'io.pressure'
        memory = self.root / 'memory.pressure'
        cpu.write_text('usage_usec 1000000\n')
        cpu_pressure.write_text('some avg10=2.0\n')
        io.write_text('some avg10=20.0\nfull avg10=3.0\n')
        memory.write_text('some avg10=5.0\nfull avg10=1.0\n')
        metrics = AdmissionMetrics(cpu, cpu_pressure, io, memory)
        self.assertIsNone(metrics.sample(10))
        cpu.write_text('usage_usec 31000000\n')
        self.assertEqual(metrics.sample(20), (3.0, 0.02, 0.20, 0.03, 0.01))
        io.unlink()
        self.assertIsNone(metrics.sample(30))

    def test_admission_uses_pressure_from_the_same_cgroup_as_cpu_usage(self):
        metrics = AdmissionMetrics.system()
        if metrics is None or not all((metrics.cpu_stat.parent / name).is_file()
                                      for name in ('cpu.pressure', 'io.pressure', 'memory.pressure')):
            self.skipTest('cgroup v2 pressure files unavailable')
        self.assertEqual(metrics.cpu_pressure.parent, metrics.cpu_stat.parent)
        self.assertEqual(metrics.io_pressure.parent, metrics.cpu_stat.parent)
        self.assertEqual(metrics.memory_pressure.parent, metrics.cpu_stat.parent)

    def test_admission_window_reports_current_pressure_and_peaks_without_slot_changes(self):
        window = build_admission.AdmissionWindow()
        window.record((1.2, 0.01, 0.60, 0.51, 0.02))
        window.record((2.0, 0.03, 0.20, 0.16, 0.04))
        summary = window.report(slots=4, jobs=50)
        self.assertIn('slots=4 cpu=2.0/50', summary)
        self.assertIn('io_full=16.0% peak_io_full=51.0%', summary)
        self.assertIn('samples=2', summary)
        window.record((3.0, 0.0, 0.13, 0.12, 0.0))
        self.assertIn('peak_io_full=12.0%', window.report(slots=4, jobs=50))

    def test_admission_window_does_not_reuse_stale_sample_after_failure(self):
        window = build_admission.AdmissionWindow()
        self.assertIn('metrics=warming-up', window.report(slots=4, jobs=50))
        window.record((1.0, 0.0, 0.21, 0.20, 0.0))
        window.record(None)
        self.assertIn('metrics=unavailable', window.report(slots=4, jobs=50))

    def test_adaptive_reservations_release_cpu_without_changing_running_jobs(self):
        states = {name: dict(jobs=25, allocation=25) for name in ('one', 'two')}
        running = {name: (None, None, dict(cpu_min=1)) for name in states}
        free_cpu = build_admission.rebalance_reservations(running, states, jobs=50, slots=3)
        self.assertGreaterEqual(free_cpu, 1)
        self.assertEqual([states[name]['jobs'] for name in running], [25, 25])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, TGOS_BUILD_JOB_BUDGET='4', BUILD_PARALLEL_TASKS='2',
                        BUILD_MEMORY_MB='2', LOG_COLOR='never', BUILD_CACHE_DIR=str(self.root / 'cache'))
        for key in ('BUILD_REBUILD', 'BUILD_CACHE', 'LOG_FILE'):
            self.env.pop(key, None)

    def node(self, name, code='pass', **kwargs):
        return dict(id=name, command=[sys.executable, '-c', code], **kwargs)

    def launch(self, tasks, **kwargs):
        manifest = self.root / 'graph.json'
        manifest.write_text(json.dumps(dict(cwd=str(self.root), tasks=tasks, **kwargs)))
        return subprocess.Popen([sys.executable, str(LIB / 'build-graph.py'), str(manifest),
                                 '--log-dir', str(self.root / 'logs')], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def finish(self, process, expected=0):
        output, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, expected, output)
        return json.loads((self.root / 'logs/state.json').read_text())

    def test_dependencies_failure_and_launch_failure(self):
        self.env['BUILD_PARALLEL_TASKS'] = '1'
        tasks = [self.node('bad', 'raise SystemExit(7)'), self.node('independent'),
                 self.node('child', 'raise AssertionError("must not run")', deps=['bad']),
                 self.node('grandchild', deps=['child']),
                 dict(id='missing', command=['/does/not/exist']), self.node('after-missing', deps=['missing'])]
        states = self.finish(self.launch(tasks), 1)
        self.assertEqual(states['bad']['status'], 7)
        for name in ('independent', 'child', 'grandchild', 'missing', 'after-missing'):
            self.assertEqual(states[name]['state'], 'cancelled')
        states = self.finish(self.launch([dict(id='missing', command=['/does/not/exist']),
                                          self.node('after-missing', deps=['missing'])]), 1)
        self.assertEqual(states['missing']['state'], 'failed')
        self.assertEqual(states['after-missing']['state'], 'cancelled')

    def test_cpu_overlap_and_reallocation(self):
        code = '''import os,time
from pathlib import Path
name=os.environ['NAME']
Path(name).write_text(os.environ['TGOS_BUILD_JOB_BUDGET'])
deadline=time.monotonic()+5
while not Path(os.environ['PEER']).exists():
 if time.monotonic()>deadline: raise RuntimeError('tasks did not overlap')
 time.sleep(.01)
'''
        tasks = [self.node('first', code, env={'NAME': 'first', 'PEER': 'second'}),
                 self.node('second', code, env={'NAME': 'second', 'PEER': 'first'}),
                 self.node('join', 'import os; assert os.environ["TGOS_BUILD_JOB_BUDGET"]=="4"', deps=['first', 'second'])]
        self.finish(self.launch(tasks))
        self.assertEqual(sum(int((self.root / name).read_text()) for name in ('first', 'second')), 4)

    def test_ready_successor_runs_before_unrelated_task(self):
        self.env['BUILD_PARALLEL_TASKS'] = '1'

        def recording_task(name, **kwargs):
            return self.node(name, "from pathlib import Path; "
                             f"Path('order').open('a').write({name!r} + '\\n')", **kwargs)

        tasks = [recording_task('qemu-aarch64.seed'),
                 recording_task('qemu-riscv64.unrelated'),
                 recording_task('qemu-aarch64.child', deps=['qemu-aarch64.seed'])]
        self.finish(self.launch(tasks))
        self.assertEqual((self.root / 'order').read_text().splitlines(),
                         ['qemu-aarch64.seed', 'qemu-aarch64.child', 'qemu-riscv64.unrelated'])

    def test_related_resource_conflict_does_not_leave_slot_idle(self):
        tasks = [self.node('qemu-aarch64.holder', 'import time; time.sleep(.6)', resources=['source']),
                 self.node('qemu-aarch64.seed', 'import time; time.sleep(.1)'),
                 self.node('qemu-riscv64.other'),
                 self.node('qemu-aarch64.child', deps=['qemu-aarch64.seed'], resources=['source'])]
        self.finish(self.launch(tasks))
        summary = (self.root / 'logs/summary.log').read_text()
        self.assertLess(summary.index('STARTED qemu-riscv64.other:'),
                        summary.index('FINISHED qemu-aarch64.holder:'))
        self.assertLess(summary.index('STARTED qemu-riscv64.other:'),
                        summary.index('STARTED qemu-aarch64.child:'))

    def test_memory_and_exclusive_resources(self):
        # O_EXCL detects real overlap instead of inspecting scheduler internals.
        code = '''import os,time
fd=os.open('exclusive',os.O_CREAT|os.O_EXCL|os.O_WRONLY)
time.sleep(.1)
os.close(fd)
os.unlink('exclusive')
'''
        for resources, memory in ((['source'], 0), ([], 2)):
            tasks = [self.node(str(n), code, resources=resources, memory_mb=memory) for n in range(3)]
            self.finish(self.launch(tasks))

    def test_pipeline_expands_cached_prepare_build_and_compose_phases(self):
        source = self.root / 'source'
        source.write_text('payload')
        pipeline = BuildPipeline('image')
        pipeline.phase('prepare',
            [sys.executable, '-c', "from pathlib import Path; Path('prepared').write_text(Path('source').read_text())"],
            cache={'inputs': ['source'], 'outputs': ['prepared']})
        pipeline.phase('build',
            [sys.executable, '-c', "from pathlib import Path; Path('staged').write_text(Path('prepared').read_text())"],
            cache={'inputs': ['prepared'], 'outputs': ['staged']})
        pipeline.phase('compose',
            [sys.executable, '-c', "from pathlib import Path; Path('image').write_text(Path('staged').read_text())"],
            cache={'inputs': ['staged'], 'outputs': ['image']})
        tasks = pipeline.tasks()
        tasks.append(self.node('consumer', "from pathlib import Path; assert Path('image').read_text()=='payload'",
                               deps=[pipeline.terminal]))

        self.finish(self.launch(tasks))
        states = self.finish(self.launch(tasks))

        self.assertEqual([task['id'] for task in tasks[:3]],
                         ['image.prepare', 'image.build', 'image.compose'])
        self.assertEqual({states[name]['state'] for name in
                          ('image.prepare', 'image.build', 'image.compose')}, {'hit'})
        self.assertEqual([states[name]['phase'] for name in
                          ('image.prepare', 'image.build', 'image.compose')],
                         ['prepare', 'build', 'compose'])
        self.assertEqual(states['consumer']['state'], 'success')

    def test_cached_dependency_outputs_automatically_invalidate_consumers(self):
        (self.root / 'source').write_text('first')
        producer = self.node('producer',
            "from pathlib import Path; Path('prepared').write_text(Path('source').read_text())",
            cache_args=['--input', 'source', '--output', 'prepared'])
        consumer = self.node('consumer',
            "from pathlib import Path; Path('image').write_text(Path('prepared').read_text())",
            deps=['producer'], cache_args=['--value', 'consumer-v1', '--output', 'image'])
        self.finish(self.launch([producer, consumer]))
        (self.root / 'source').write_text('second')

        states = self.finish(self.launch([producer, consumer]))

        self.assertEqual(states['producer']['state'], 'success')
        self.assertEqual(states['consumer']['state'], 'success')
        self.assertEqual((self.root / 'image').read_text(), 'second')

    def test_invalid_graph_does_not_execute_and_signal_releases_lock(self):
        tasks = [self.node('cycle', "open('unexpected','w').close()", deps=['cycle'])]
        process = self.launch(tasks)
        output, _ = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertFalse((self.root / 'unexpected').exists())
        tasks = [self.node('running', "import time; open('started','w').close(); time.sleep(30)")]
        lock = str(self.root / 'workspace.lock')
        process = self.launch(tasks, locks=[lock])
        deadline = time.monotonic() + 5
        while not (self.root / 'started').exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((self.root / 'started').exists())
        process.send_signal(signal.SIGTERM)
        states = self.finish(process, 1)
        self.assertEqual(states['running']['state'], 'cancelled')
        self.finish(self.launch([self.node('after')], locks=[lock]))

    def test_task_workspace_lock_does_not_block_unrelated_work(self):
        lock = self.root / 'busy.lock'
        with lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            process = self.launch([
                self.node('busy.task', "open('busy.done', 'w').close()", locks=[str(lock)]),
                self.node('free.task', "open('free.done', 'w').close()")])
            deadline = time.monotonic() + 3
            while not (self.root / 'free.done').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.root / 'free.done').exists())
            self.assertFalse((self.root / 'busy.done').exists())
            fcntl.flock(held, fcntl.LOCK_UN)
        self.finish(process)
        self.assertTrue((self.root / 'busy.done').exists())

    def test_invalid_late_environment_is_rejected_before_any_task(self):
        self.env['BUILD_PARALLEL_TASKS'] = '1'
        process = self.launch([self.node('first', "open('unexpected','w').close()"),
                               self.node('invalid', env={'BAD': 1})])
        output, _ = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertFalse((self.root / 'unexpected').exists())

    def test_failed_leader_does_not_leave_background_writer(self):
        child = "import time; time.sleep(.6); open('late-output','w').close()"
        code = f'import subprocess,sys; subprocess.Popen([sys.executable,"-c",{child!r}]); sys.exit(7)'
        self.finish(self.launch([self.node('bad', code)]), 1)
        time.sleep(.7)
        self.assertFalse((self.root / 'late-output').exists())

    def test_heartbeat_reports_active_progress_and_wait_reasons(self):
        self.env.update(TGOS_BUILD_JOB_BUDGET='2', BUILD_PARALLEL_TASKS='1', BUILD_HEARTBEAT_SECONDS='0.1')
        active = '''import time
print("compiling drivers/virtio/virtio_ring.o", flush=True)
time.sleep(.35)
'''
        tasks = [self.node('active', active), self.node('resource-wait'),
                 self.node('dependency-wait', deps=['active'])]
        process = self.launch(tasks)
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        step_log = self.root / 'logs/steps/active.log'
        self.assertIn(f'STARTED active: jobs=2 log={step_log}', output)
        self.assertRegex(output, r'RUNNING active: elapsed=0\.[0-9]+s jobs=2 ')
        self.assertIn(f'log={step_log}', output)
        self.assertIn('last=compiling drivers/virtio/virtio_ring.o', output)
        self.assertIn('WAITING graph: dependencies=1 resources=1', output)

    def test_cgroup_heartbeat_reports_admission_when_slots_are_unchanged(self):
        if AdmissionMetrics.system() is None:
            self.skipTest('cgroup v2 pressure files unavailable')
        self.env.update(TGOS_BUILD_JOB_BUDGET='2', TGOS_CPU_SCOPE_ACTIVE='1',
                        BUILD_HEARTBEAT_SECONDS='0.1')
        self.env.pop('BUILD_PARALLEL_TASKS')
        process = self.launch([self.node('active', 'import time; time.sleep(.4)')])
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        self.assertRegex(output, r'ADMISSION graph: mode=normal slots=\d+ metrics=warming-up')

    def test_io_stall_paces_real_graph_launches_and_caps_new_jobs(self):
        spec = importlib.util.spec_from_file_location('build_graph_test', LIB / 'build-graph.py')
        scheduler = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scheduler)

        class StalledMetrics:
            def sample(self, _now):
                return (1.2, 0.0, 0.51, 0.50, 0.0)

        code = ('import os,time; from pathlib import Path; '
                'Path(os.environ["NAME"]).write_text('
                'f"{time.monotonic()} {os.environ[\'TGOS_BUILD_JOB_BUDGET\']}")')
        graph = {'cwd': str(self.root), 'tasks': [self.node(name, code, env={'NAME': name})
                                                  for name in ('first', 'second')]}
        env = dict(self.env, TGOS_BUILD_JOB_BUDGET='8', TGOS_CPU_SCOPE_ACTIVE='1')
        env.pop('BUILD_PARALLEL_TASKS')
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(scheduler.AdmissionMetrics, 'system', return_value=StalledMetrics()), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(scheduler.execute(graph, self.root / 'logs'), 0)
        first_started, first_jobs = map(float, (self.root / 'first').read_text().split())
        second_started, second_jobs = map(float, (self.root / 'second').read_text().split())
        self.assertGreaterEqual(second_started - first_started, 9.5)
        self.assertLess(first_jobs, 8)
        self.assertLess(second_jobs, 8)

    def test_failure_reports_step_log_path(self):
        process = self.launch([self.node('bad', 'raise SystemExit(7)')])
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, output)
        self.assertIn(f'FAILED bad: status=7 log={self.root / "logs/steps/bad.log"}', output)

    def test_task_receives_its_owned_log_file(self):
        code = '''import os
from pathlib import Path
path = Path(os.environ["LOG_FILE"])
assert path.name == "direct-log.log"
with path.open("a") as stream:
    stream.write("direct append\\n")
print("captured after append", flush=True)
'''
        process = self.launch([self.node('direct-log', code)])
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        contents = (self.root / 'logs/steps/direct-log.log').read_text()
        self.assertIn('direct append', contents)
        self.assertIn('captured after append', contents)

    def test_automatic_budget_preserves_cpu_headroom(self):
        self.env.pop('TGOS_BUILD_JOB_BUDGET')
        fake_bin = self.root / 'fake-bin'
        fake_bin.mkdir()
        fake_nproc = fake_bin / 'nproc'
        fake_nproc.write_text('#!/bin/sh\nprintf "8\\n"\n')
        fake_nproc.chmod(0o755)
        self.env['PATH'] = f'{fake_bin}{os.pathsep}{self.env["PATH"]}'
        process = self.launch([self.node('only')])
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        match = re.search(r'START graph: tasks=1 jobs=([0-9]+)', output)
        self.assertIsNotNone(match, output)
        self.assertGreater(int(match.group(1)), 0)
        self.assertGreater(int(match.group(1)), 1)
        self.assertLess(int(match.group(1)), 8)

    def test_cgroup_default_starts_with_conservative_slots_and_respects_override(self):
        self.env.update(TGOS_BUILD_JOB_BUDGET='50', TGOS_CPU_SCOPE_ACTIVE='1')
        fake_bin = self.root / 'fake-bin'
        fake_bin.mkdir()
        fake_nproc = fake_bin / 'nproc'
        fake_nproc.write_text('#!/bin/sh\nprintf "80\\n"\n')
        fake_nproc.chmod(0o755)
        self.env['PATH'] = f'{fake_bin}{os.pathsep}{self.env["PATH"]}'
        self.env.pop('BUILD_PARALLEL_TASKS')
        process = self.launch([self.node('only')])
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        self.assertIn('jobs=50', output)
        first_slots = int(re.search(r'\bslots=(\d+)\b', output).group(1))
        self.env['TGOS_BUILD_JOB_BUDGET'] = '10'
        process = self.launch([self.node('only')])
        smaller_output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, smaller_output)
        smaller_slots = int(re.search(r'\bslots=(\d+)\b', smaller_output).group(1))
        self.assertLess(smaller_slots, first_slots)
        self.env['TGOS_BUILD_JOB_BUDGET'] = '50'
        self.env['BUILD_PARALLEL_TASKS'] = '4'
        process = self.launch([self.node('only')])
        output, _ = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output)
        self.assertIn('jobs=50 slots=4 cpu=cgroup', output)

if __name__ == '__main__':
    unittest.main()
