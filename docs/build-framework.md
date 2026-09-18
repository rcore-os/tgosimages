# Shared build acceleration

For mandatory directory, patch, cleanup and integration requirements, see the
[Chinese integration specification](build-framework_CN.md). These requirements apply to every platform, OS, rootfs, application and helper;
Zephyr is a migration example. All targets must keep
source checkouts separate from object directories under `build/objects/`; the
legacy CMake compatibility mechanism is not permission to create new in-tree
build directories.

Source `scripts/lib/utils.sh` once. New host build scripts use `build_make`,
`build_cmake`, `build_cargo`, or `build_scons` instead of supplying their own
parallelism and cache policy. These functions preserve argument arrays, report
elapsed time and propagate tool failures. They do not evaluate command strings.

## Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `BUILD_JOBS` | `nproc` | Total compiler budget for this invocation |
| `BUILD_PARALLEL_TASKS` | Current job budget | Maximum simultaneous tasks at each parallel boundary |
| `BUILD_CACHE` | `1` | `0` disables compiler/task caching; `1`/`auto` use available backends |
| `BUILD_CACHE_DIR` | `build/.cache` | Compiler caches and task manifests |
| `BUILD_REBUILD` | `0` | `1` bypasses whole-task hits and refreshes successful records |
| `BUILD_WORKSPACE_ROOT` | `build/workspaces` | Persistent isolated task workspaces |
| `BUILD_SOURCE_CACHE_DIR` | `<BUILD_CACHE_DIR>/git` | Shared Git download cache |
| `LOG_COLOR` | `auto` | Terminal color policy: `auto`, `always`, `never` |

Existing `CCACHE_DIR`, `CMAKE_C_COMPILER_LAUNCHER`, `CMAKE_CXX_COMPILER_LAUNCHER`,
`CARGO_BUILD_JOBS` and `RUSTC_WRAPPER` overrides remain supported. Explicit
per-tool concurrency overrides can exceed the framework's automatic budget;
new targets should not hard-code `-j` values. Ccache and sccache are optional:
missing tools fall back to normal compilation. The source tree is not a cache
of finished binaries. Standard tool dependency checking still runs.

`run_parallel_functions` and the top-level OS/rootfs runner divide the inherited
budget among active slots. Excess tasks wait; sequential batches retain their
budget. The cap applies to participating tasks in one invocation, not to other
users, other independent builds, remote SDK builders or arbitrary subprocesses
that ignore the adapters. Do not parallelize users of a mutable source tree
without isolating that tree or locking its entire preparation/build lifetime.

### Architecture workspaces

`platform qemu all` runs four architecture jobs through the parallel scheduler;
`platform all` invokes this group in its QEMU phase. Within each architecture,
OS and rootfs steps divide the inherited budget again. Failures are aggregated
after all architecture jobs complete; set `BUILD_PARALLEL_TASKS=1` to serialize.

New launchers may use `build_workspace_run <task-id> <executable> [args...]`.
It holds a persistent per-workspace lock across the complete command and sets
`BUILD_WORK_DIR` for every descendant. Scripts initialize `BUILD_DIR` through
`build_paths_init`; they must not reconstruct `ROOT_DIR/build` themselves.
Direct QEMU commands reenter through the same workspace launcher, so direct and
batch invocations for one architecture cannot modify its tree simultaneously.

Source copies belong to `build/workspaces/qemu-<arch>/`; final QEMU and rootfs
artifacts retain their architecture-specific `IMAGES/` names. Explicit mutable
source overrides outside the workspace are rejected. Read-only toolchains can
still be shared. Git clones/ref fetches share a locked bare download cache,
while each checkout has its own Git objects and patch state (no alternates or
hardlinks). Clearing the download cache does not invalidate existing checkouts.
New clones refresh the cached upstream default branch; pinned commit downloads
are reused. Download caching is separate from compiler/task cache policy.

Old build directories are preserved. New architecture workspaces start cold;
there is no automatic move or deletion of user source caches. Stop builds before
running `cleanall`, which also removes default workspaces and their locks.

### Console colors

Shared messages use cyan/green/yellow/red for progress/success/warnings/errors,
plus distinct colors for QEMU architecture names. Auto mode honors `NO_COLOR`
and `TERM=dumb`. Forced colors apply to the console, after the plain log stream
has been saved; captured child streams stay uncolored. Raw tool output is not
reformatted. Use `LOG_COLOR=never` for plain console output.

## Compiler and object reuse

Make/SCons use compiler aliases through ccache, preserving the compiler selected
by each project (including LLVM builds that also set `CROSS_COMPILE`). CMake receives compiler launchers and its build parallelism
through the common adapter, including Zephyr's native launcher interaction.
Cargo uses sccache when installed unless a caller supplies a Rust wrapper.
An explicitly absolute Make compiler path or `CROSS_COMPILE` prefix bypasses aliases; use
`CC="ccache /path/to/compiler"` if that toolchain needs caching.

Keep CMake/Make output directories stable and separate per target, architecture
and incompatible configuration. Never remove another target's intermediate
files to gain concurrency. Existing target-specific cleanup remains in place;
compiler caches survive ordinary target clean, but `build.sh cleanall` removes
`build/` including its default caches. Set `BUILD_CACHE_DIR` outside `build/` to
retain caches across cleanall.

## Patch-aware source preparation

After cloning, call:

```bash
clone_repository "$repo_url" "$source_dir"
prepare_patched_source "$source_dir" "$pinned_ref" "$patch_dir"
```

This compares the resolved base commit, ordered patch contents and the actual
patched source state. Patch order is lexically sorted `*.patch`, then `*.diff`,
matching `apply_patches`. Adding, removing, renaming or editing a patch invalidates
the preparation record. For an unchanged verified tree, checkout and patch
application are skipped, preserving file timestamps and intermediate builds.

Old `.applied` markers alone prove nothing. Legacy trees are compared against
an expected tree assembled using a private Git index. Overlapping patches are
verified as a complete sequence. Known managed trees can be reset when inputs
change; unverified local edits are preserved and reported instead of reset.
Failed patch application does not publish success; the known partial state can
be safely reset on retry. Existing direct `checkout_ref` callers still clear
patch markers and reapply patches. QEMU and Zephyr use the new preparation API. Zephyr now places new objects
under `build/objects/zephyr/`, outside the source checkout. Recognizable legacy
CMake output directories inside a checkout are added to its local Git exclude
file only when their cache records match their path and they contain no tracked
files; they are preserved during subsequent source preparation.

## Whole-task incremental cache (explicit opt-in)

The adapters above enable compiler caching automatically. Skipping a complete
task requires declaring its inputs; the framework cannot infer arbitrary shell
script dependencies. Existing image build tasks are **not** silently skipped.

```bash
# Prepare source first, then validate/execute the artifact-producing task.
build_task "kernel-$arch" \
    --source-ref "$source_dir" "$pinned_ref" \
    --patch-dir "$patch_dir" \
    --input "$config_file" \
    --input "$build_driver" \
    --input "$toolchain_manifest" \
    --input "$dependency_artifact" \
    --env CROSS_COMPILE --env CFLAGS \
    --tool "${CROSS_COMPILE}gcc" \
    --value "arch=$arch" \
    --output "$kernel_image" \
    -- bash "$build_driver" "$arch"
```

The command must be an executable; use a small driver script that sources utils
for shell functions. Include that script and sourced build logic as inputs.
Declare toolchain/sysroot manifests, configuration, artifact-affecting environment,
dependency artifacts and generated/ignored source inputs. `--source-ref` hashes
tracked changes and nonignored untracked files, including submodules; ignored
files need explicit `--input` declarations. Directory inputs hash all contents.
Inputs and outputs must not overlap. Each task must own its outputs; independent
task names must not concurrently write the same output paths.

Hits require identical inputs and content/mode checksums of all outputs.
Per-task file locks prevent duplicate concurrent execution; successful records
are atomically published. Failures, missing outputs and source changes during
execution never publish a new successful record. Cache logs distinguish changed
inputs, missing/modified outputs, forced rebuilds and verified hits.

## Validation

Run `bash scripts/tests/build-performance.sh` on Linux. It exercises actual
Make/CMake compilation, ccache hits, budget enforcement, task concurrency,
input/ref/patch/environment invalidation, output tampering, overlapping patches,
legacy adoption, local-edit preservation, and failed-patch retries.

`python3 scripts/tests/qemu-parallel.py` verifies real overlapping architecture
dispatch, isolated patches/configurations, shared downloads, concurrent limits,
failure aggregation, and single-architecture locking with local Git fixtures.
Terminal color routing is covered by `scripts/tests/build-review-regressions.py`.
