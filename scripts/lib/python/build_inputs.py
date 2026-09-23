"""Content identities shared by shell patching and Python task caching."""
import hashlib
import json
import os
from pathlib import Path
import sys


def patch_set(directory):
    root = Path(directory).absolute()
    entries = []
    # Keep this ordering identical to apply_patches' two shell globs.
    for path in sorted(root.glob('*.patch'), key=lambda p: os.fsencode(p.name)) + sorted(root.glob('*.diff'), key=lambda p: os.fsencode(p.name)):
        if path.is_file():
            entries.append((path.name, hashlib.sha256(path.read_bytes()).hexdigest()))
    return dict(directory=str(root), exists=root.is_dir(), patches=entries)


def source_state(repo, ref='HEAD'):
    import os
    import subprocess
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args])
    commit = git('rev-parse', '--verify', f'{ref}^{{commit}}').decode().strip()
    delta = git('diff', '--no-ext-diff', '--no-textconv', '--binary', commit, '--')
    extra = {}
    for filename in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
        if not filename:
            continue
        name = os.fsdecode(filename)
        if name.startswith('.patch_stamps/'):
            continue
        path = Path(repo) / name
        # Match Git's symlink semantics; external targets are explicit inputs.
        content = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
        extra[name] = dict(kind='symlink' if path.is_symlink() else 'file',
                           mode=path.lstat().st_mode & 0o777,
                           sha256=hashlib.sha256(content).hexdigest())
    submodules = {}
    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if entry.startswith(b'160000 '):
            name = os.fsdecode(entry.split(b'\t', 1)[1])
            subrepo = Path(repo) / name
            target = entry.split(b' ', 2)[1].decode('ascii')
            if subrepo.is_dir() and Path(subprocess.check_output(
                    ['git', '-C', str(subrepo), 'rev-parse', '--show-toplevel'],
                    stderr=subprocess.DEVNULL).decode().strip()).resolve() == subrepo.resolve():
                state = source_state(subrepo)
            else:
                state = 'uninitialized'
            submodules[name] = dict(commit=target, state=state)
    return dict(repo=str(Path(repo).resolve()), commit=commit,
                diff=hashlib.sha256(delta).hexdigest(), untracked=extra, submodules=submodules)


def verify_patch_tree(repo, ref, directory):
    """Read-only worktree check using private Git indexes; no checkout/reset."""
    import os
    import subprocess
    import tempfile
    repo = str(Path(repo).resolve())
    with tempfile.TemporaryDirectory(prefix='tgos-patch-index-') as temp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temp) / 'index'))
        def git(*args):
            return subprocess.check_output(['git', '-C', repo, *args], env=env, stderr=subprocess.DEVNULL)
        git('read-tree', ref)
        for name, _ in patch_set(directory)['patches']:
            patch = str(Path(directory).resolve() / name)
            try:
                git('apply', '--cached', '--whitespace=nowarn', patch)
            except subprocess.CalledProcessError:
                git('apply', '--cached', '-p0', '--whitespace=nowarn', patch)
        expected = git('write-tree')
        git('read-tree', 'HEAD')
        git('add', '-A', '--', '.', ':!.patch_stamps')
        return expected == git('write-tree')


def protect_cmake_outputs(repo):
    """Preserve recognizable legacy out-of-source CMake trees inside a checkout."""
    import subprocess
    root = Path(repo).resolve()
    protected = []
    for directory in root.iterdir():
        cache = directory / 'CMakeCache.txt'
        if directory.is_symlink() or not cache.is_file():
            continue
        expected = f'CMAKE_CACHEFILE_DIR:INTERNAL={directory}'
        if expected not in cache.read_text(errors='replace').splitlines():
            continue
        tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--', directory.name])
        if tracked:
            continue
        protected.append(directory.name)
    if not protected:
        return
    info = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--git-path', 'info/exclude']).decode().strip()
    exclude = Path(info)
    if not exclude.is_absolute():
        exclude = root / exclude
    exclude.parent.mkdir(parents=True, exist_ok=True)
    previous = exclude.read_text() if exclude.exists() else ''
    lines = previous.splitlines()
    for name in protected:
        if '\n' in name or '\r' in name:
            raise ValueError('unsupported CMake output directory name')
        escaped = ''.join('\\' + ch if ch in '\\[]*?!# ' else ch for ch in name)
        pattern = '/' + escaped + '/'
        if pattern not in lines:
            lines.append(pattern)
    updated = '\n'.join(lines) + '\n'
    if previous != updated:
        exclude.write_text(updated)


if __name__ == '__main__':
    if sys.argv[1] == '--protect-cmake-outputs':
        protect_cmake_outputs(sys.argv[2])
        sys.exit(0)
    if sys.argv[1] == '--verify':
        import subprocess
        try:
            sys.exit(0 if verify_patch_tree(*sys.argv[2:]) else 1)
        except (OSError, subprocess.CalledProcessError):
            sys.exit(1)
    data = source_state(sys.argv[2]) if sys.argv[1] == '--source' else patch_set(sys.argv[1])
    print(hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest())
