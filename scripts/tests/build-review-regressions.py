#!/usr/bin/env python3
"""Regression checks for compiler selection, worker exits and cache identity."""
import importlib.util
import os
import errno
import pty
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/lib'))
spec = importlib.util.spec_from_file_location('task_cache', ROOT / 'scripts/lib/build-task.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
from build_inputs import source_state


def run(command, **kwargs):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(timeout=12)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError('command hung: ' + str(command))
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = dict(os.environ, LOG_CREATE_DEFAULT_FILE='0', BUILD_JOBS='2',
                        BUILD_CACHE_DIR=str(self.work / 'cache'))
        for key in ('LOG_FILE', 'LOG_STDIO_CAPTURED', 'CC', 'CROSS_COMPILE',
                    'CCACHE_DISABLE', 'BUILD_CACHE', 'TGOS_BUILD_JOB_BUDGET', 'LOG_COLOR', 'NO_COLOR'):
            self.env.pop(key, None)

    def shell(self, body):
        return run(['bash', '-c', 'set -eu; source "$1/scripts/lib/utils.sh"; ' + body,
                    '_', str(ROOT), str(self.work)], env=self.env)

    def test_make_keeps_project_compiler(self):
        fake_bin = self.work / 'bin'
        fake_bin.mkdir()
        ccache = fake_bin / 'ccache'
        ccache.write_text('#!/bin/sh\nexit 99\n')
        ccache.chmod(0o755)
        self.env['PATH'] = str(fake_bin) + ':' + self.env['PATH']
        (self.work / 'Makefile').write_text('CC = chosen-clang\nall:\n\t@printf "%s\\n" "$(CC)"\n')
        result = self.shell('build_make -C "$2" CROSS_COMPILE=aarch64-linux-gnu- LLVM=1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('chosen-clang\n', result.stdout)

    def test_worker_death_does_not_hang(self):
        result = self.shell('''
log_format() {
    if [[ ${2:-} == 'START %s' && ${3:-} == victim ]]; then
        kill -KILL "$BASHPID"
    fi
    local level=$1 format=$2
    shift 2
    printf '[%s] ' "$level"
    printf "$format" "$@"
    printf '\\n'
}
victim() { :; }
PARALLEL_LOG_DIR="$2/logs" run_parallel_functions batch victim --
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAILED victim: status=137', result.stdout)

    def test_top_level_worker_death_does_not_hang(self):
        fixture = self.work / 'repo'
        (fixture / 'scripts/rootfs').mkdir(parents=True)
        shutil.copy2(ROOT / 'build.sh', fixture / 'build.sh')
        shutil.copytree(ROOT / 'scripts/lib', fixture / 'scripts/lib')
        for name in ('busybox', 'alpine', 'debian'):
            script = fixture / f'scripts/rootfs/{name}.sh'
            script.write_text('#!/bin/bash\n' +
                              ('kill -KILL "$PPID"\n' if name == 'busybox' else '') + 'exit 0\n')
            script.chmod(0o755)
        env = dict(self.env, LOG_DIR=str(self.work / 'logs'))
        result = run(['bash', str(fixture / 'build.sh'), 'rootfs', 'all'], env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAILED busybox: status=137', result.stdout)

    def test_file_cannot_impersonate_empty_directory(self):
        directory = self.work / 'directory'
        directory.mkdir(mode=0o755)
        file = self.work / 'file'
        file.write_bytes(b'directory\0')
        file.chmod(0o755)
        self.assertNotEqual(cache.digest(directory), cache.digest(file))

    def test_orangepi_stops_failed_parallel_step(self):
        result = self.shell('''
source "$1/scripts/platform/orangepi-5-plus.sh"
LOG_DIR="$2/logs"
linux() { :; }
rootfs() { :; }
uboot() { false; printf 'wrongly-continued\\n'; }
arceos() { :; }
starry() { :; }
zephyr() { :; }
freertos() { :; }
ivc() { :; }
orangepi_build_base_image() { printf 'wrongly-built\\n'; }
finalize_linux_image() { :; }
all
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('wrongly-', result.stdout)

    def test_source_symlink_and_file_have_distinct_identity(self):
        subprocess.run(['git', 'init', '-q', str(self.work)], check=True)
        subprocess.run(['git', '-C', str(self.work), '-c', 'user.name=test', '-c',
                        'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'base'], check=True)
        source = self.work / 'input'
        source.write_text('external-header')
        source.chmod(0o777)
        before = source_state(self.work)
        source.unlink()
        source.symlink_to('external-header')
        self.assertNotEqual(before, source_state(self.work))

    def test_tool_changed_during_build_is_not_cached(self):
        tool = self.work / 'tool'
        tool.write_text('#!/bin/sh\nexit 0\n')
        tool.chmod(0o755)
        driver = self.work / 'driver.sh'
        driver.write_text('printf changed >> "$1"\nprintf output > "$2"\n')
        result = self.shell('build_task changing-tool --input "$2/driver.sh" '
                            '--tool "$2/tool" --output "$2/output" -- '
                            'bash "$2/driver.sh" "$2/tool" "$2/output"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list((self.work / 'cache/tasks').glob('*.json')))

    def test_forced_console_color_keeps_framework_logs_plain(self):
        fixture = self.work / 'repo'
        (fixture / 'scripts/platform').mkdir(parents=True)
        shutil.copytree(ROOT / 'scripts/lib', fixture / 'scripts/lib')
        script = fixture / 'scripts/platform/color.sh'
        env = dict(self.env, LOG_COLOR='always', LOG_CREATE_DEFAULT_FILE='1')
        # Both stdio owners must color the console after saving plain logs.
        for entry in ('platform-log', 'utils'):
            with self.subTest(entry=entry):
                init = 'platform_log_init "$@"\n' if entry == 'platform-log' else ''
                script.write_text('#!/bin/bash\nset -eu\n'
                                  'ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd -P)\n'
                                  f'source "$ROOT_DIR/scripts/lib/{entry}.sh"\n' + init +
                                  "info 'STARTED qemu-aarch64'\nsuccess 'DONE qemu-x86_64'\n")
                result = run(['bash', str(script), 'all'], env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('\x1b[', result.stdout)
                logs = list((fixture / 'logs').rglob('*.log'))
                self.assertTrue(logs)
                for path in logs:
                    self.assertNotIn('\x1b', path.read_text())

    def test_auto_color_requires_terminal_and_respects_no_color(self):
        command = ['bash', '-c', 'source "$1/scripts/lib/log.sh"; '
                   'log_summary "$2/summary.log" ERROR "FAILED qemu-aarch64"',
                   '_', str(ROOT), str(self.work)]
        result = run(command, env=dict(self.env, TERM='xterm'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('\x1b', result.stdout)
        for disabled in (False, True):
            master, slave = pty.openpty()
            env = dict(self.env, TERM='xterm')
            if disabled:
                env['NO_COLOR'] = ''
            try:
                process = subprocess.Popen(command, env=env, stdout=slave, stderr=slave)
                os.close(slave)
                self.assertEqual(process.wait(timeout=5), 0)
                output = b''
                while True:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output += chunk
            finally:
                os.close(master)
            self.assertEqual(b'\x1b[' in output, not disabled)
        self.assertNotIn('\x1b', (self.work / 'summary.log').read_text())


if __name__ == '__main__':
    unittest.main()
