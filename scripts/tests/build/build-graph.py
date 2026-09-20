#!/usr/bin/env python3
"""Check dependency/resource contracts with real subprocesses and task caching."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lib/python'))
from build_pipeline import BuildPipeline

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / 'scripts/lib/python'


class GraphTests(unittest.TestCase):
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
        tasks = [self.node('bad', 'raise SystemExit(7)'), self.node('independent'),
                 self.node('child', 'raise AssertionError("must not run")', deps=['bad']),
                 self.node('grandchild', deps=['child']),
                 dict(id='missing', command=['/does/not/exist']), self.node('after-missing', deps=['missing'])]
        states = self.finish(self.launch(tasks), 1)
        self.assertEqual(states['bad']['status'], 7)
        self.assertEqual(states['independent']['state'], 'success')
        for name in ('child', 'grandchild', 'after-missing'):
            self.assertEqual(states[name]['state'], 'blocked')

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

    def test_cache_hit_unblocks_consumer(self):
        (self.root / 'input').write_text('source')
        code = "from pathlib import Path; Path('output').write_text(Path('input').read_text())"
        tasks = [self.node('cached', code, cache_args=['--input', 'input', '--output', 'output']),
                 self.node('consumer', "from pathlib import Path; assert Path('output').read_text()=='source'", deps=['cached'])]
        self.finish(self.launch(tasks))
        states = self.finish(self.launch(tasks))
        self.assertEqual(states['cached']['state'], 'hit')

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

    def test_cpu_scope_adds_headroom_for_a_quarter_of_active_nodes(self):
        self.env.update(TGOS_BUILD_JOB_BUDGET='8', BUILD_PARALLEL_TASKS='4',
                        TGOS_CPU_SCOPE_ACTIVE='1')
        fake_bin = self.root / 'fake-bin'
        fake_bin.mkdir()
        fake_nproc = fake_bin / 'nproc'
        fake_nproc.write_text('#!/bin/sh\nprintf "16\\n"\n')
        fake_nproc.chmod(0o755)
        self.env['PATH'] = f'{fake_bin}{os.pathsep}{self.env["PATH"]}'
        code = '''import os,time
from pathlib import Path
name=os.environ["NAME"]
Path(name).write_text(os.environ["TGOS_BUILD_JOB_BUDGET"])
while len(list(Path(".").glob("node-*"))) < 4:
    time.sleep(.01)
time.sleep(.1)
'''
        tasks = [self.node(f'task-{index}', code, env={'NAME': f'node-{index}'})
                 for index in range(4)]
        process = self.launch(tasks)
        output, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, output)
        self.assertEqual({(self.root / f'node-{index}').read_text() for index in range(4)}, {'3'}, output)


if __name__ == '__main__':
    unittest.main()
