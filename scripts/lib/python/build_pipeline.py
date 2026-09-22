#!/usr/bin/env python3
"""Declarative build phases expanded into ordinary build-graph tasks."""


_CACHE_OPTIONS = {
    'inputs': '--input',
    'mutable_inputs': '--mutable-input',
    'outputs': '--output',
    'values': '--value',
    'environment': '--env',
    'tools': '--tool',
    'patches': '--patch-dir',
}


def cache_arguments(contract):
    if not isinstance(contract, dict) or set(contract) - (_CACHE_OPTIONS.keys() | {'sources'}):
        raise ValueError('invalid task cache contract')
    if not contract.get('outputs'):
        raise ValueError('cached task must declare outputs')
    arguments = []
    for key, option in _CACHE_OPTIONS.items():
        values = contract.get(key, [])
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise ValueError(f'cache {key} must be a list of strings')
        for value in values:
            arguments.extend((option, value))
    sources = contract.get('sources', [])
    if not isinstance(sources, list):
        raise ValueError('cache sources must be a list')
    for source in sources:
        if not isinstance(source, list) or len(source) != 2 or not all(isinstance(value, str) for value in source):
            raise ValueError('cache source must contain repository and ref strings')
        arguments.extend(('--source-ref', *source))
    return arguments


def phase_task(task_id, phase, command, *, deps=None, env=None, resources=None,
               cache=None, cpu_min=None, cpu_max=None, memory_mb=None):
    task = dict(id=task_id, phase=phase, command=list(command), deps=list(deps or []),
                env=dict(env or {}), resources=list(resources or []))
    if cache is not None:
        task['cache_args'] = cache_arguments(cache)
    for key, value in (('cpu_min', cpu_min), ('cpu_max', cpu_max), ('memory_mb', memory_mb)):
        if value is not None:
            task[key] = value
    return task


class BuildPipeline:
    """Build a linear phase chain while keeping phase nodes independently cacheable."""

    def __init__(self, pipeline_id, *, deps=None, env=None, resources=None):
        self.pipeline_id = pipeline_id
        self.deps = list(deps or [])
        self.env = dict(env or {})
        self.resources = list(resources or [])
        self._tasks = []
        self._phases = set()

    @property
    def terminal(self):
        if not self._tasks:
            raise ValueError('pipeline has no phases')
        return self._tasks[-1]['id']

    def phase(self, name, command, *, task_id=None, deps=None, env=None, resources=None,
              cache=None, cpu_min=None, cpu_max=None, memory_mb=None):
        if not name or name in self._phases:
            raise ValueError(f'invalid or duplicate pipeline phase: {name}')
        phase_deps = [self.terminal] if self._tasks else list(self.deps)
        phase_deps.extend(deps or [])
        phase_env = dict(self.env)
        phase_env.update(env or {})
        task = phase_task(task_id or f'{self.pipeline_id}.{name}', name, command,
                          deps=phase_deps, env=phase_env,
                          resources=self.resources if resources is None else resources,
                          cache=cache, cpu_min=cpu_min, cpu_max=cpu_max,
                          memory_mb=memory_mb)
        self._phases.add(name)
        self._tasks.append(task)
        return task

    def tasks(self):
        if not self._tasks:
            raise ValueError('pipeline has no phases')
        return list(self._tasks)
