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
| `BUILD_CACHE` | `1` | `0` disables framework caches; `1`/`auto` use available backends |
| `BUILD_CACHE_DIR` | `build/.cache` | Compiler caches and task manifests |
| `BUILD_REBUILD` | `0` | `1` bypasses whole-task hits and refreshes successful records |

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
