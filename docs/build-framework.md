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
| `BUILD_JOBS` | `32` | Total compiler budget for this invocation |
| `BUILD_PARALLEL_TASKS` | Current job budget | Global graph task cap; per-boundary cap for legacy runners |
| `BUILD_HEARTBEAT_SECONDS` | `60` | Graph heartbeat interval; active nodes include elapsed time, jobs, log path, and latest progress |
| `BUILD_MEMORY_MB` | `0` | Admission budget for declared graph memory; 0 disables it |
| `BUILD_CACHE` | `1` | `0` disables compiler/task caching; `1`/`auto` use available backends |
| `BUILD_CACHE_DIR` | `build/.cache` | Compiler caches and task manifests |
| `BUILD_REBUILD` | `0` | `1` bypasses whole-task hits and refreshes successful records |
| `BUILD_WORKSPACE_ROOT` | `build/workspaces` | Persistent isolated task workspaces |
| `BUILD_SOURCE_CACHE_DIR` | `<BUILD_CACHE_DIR>/git` | Shared Git download cache |
| `ROOTFS_GUEST_COUNT` | `2` | Positive number of zero-based nested guest rootfs files; resource-limited, no fixed maximum |
| `LOG_COLOR` | `auto` | Terminal color policy: `auto`, `always`, `never` |

Existing `CCACHE_DIR`, `CMAKE_C_COMPILER_LAUNCHER`, `CMAKE_CXX_COMPILER_LAUNCHER`,
`RUSTC_WRAPPER` overrides remain supported. The graph scheduler sets
`CARGO_BUILD_JOBS` to the allocated CPU budget; legacy runners preserve explicit
Cargo overrides. Explicit
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

`platform all` merges component tasks for seven boards and four QEMU architectures
into one graph and one scheduler invocation. Platform/architecture names are
groups, not nested worker pools. `platform qemu all` and single-board commands
select the corresponding subgraph and required dependencies. Completed tasks release
tokens to newly ready tasks; running Make/Ninja processes are not resized.
Composition depends on every component of its architecture, including before
IVC preparation modifies Linux/ArceOS sources. Failed dependencies block their
descendants while independent tasks continue. Set `BUILD_PARALLEL_TASKS=1` to
serialize. Source preparation and patch validation remain inside component
tasks. Orange Pi rootfs follows Linux because they share an upstream checkout;
IVC follows Starry/Zephyr, base-image creation follows all payloads, and final
composition follows the base image. Phytium Pi, ROC and EVM rootfs injection is a
separate dependent node; injection failure now fails Phytium Pi as well.
`platform clean` still cleans platforms sequentially, taking the same workspace
locks. QEMU clean retains its workspace launcher.

Board declarations live in `scripts/lib/platform-tasks.json`: `components`
names executable shell functions, `deps` declares edges, `resources` declares
exclusion, `private` hides internal stages, and `compose` requests rootfs
injection. `platform-graph.py` merges declarations; `platform-node.sh` loads
the platform in a fresh Bash and executes one step. Register new CLI targets
and source `platform-graph-entry.sh` before initializing their build paths.
Do not add a new scheduler for each platform.

ROC, EVM and RDK Linux SDK nodes share the `vendor-sdk` exclusion key within
the graph. Vendor SDKs still control their own threads: local budgets cannot
enforce remote CPU limits or prevent direct SDK use from other machines.
Server-side locking/resource control remains necessary for those environments.

New launchers may use `build_workspace_run <task-id> <executable> [args...]`.
It holds a persistent per-workspace lock across the complete command and sets
`BUILD_WORK_DIR` for every descendant. Scripts initialize `BUILD_DIR` through
`build_paths_init`; they must not reconstruct `ROOT_DIR/build` themselves.
The graph scheduler holds the same workspace locks, so direct, batch and clean
invocations for one architecture cannot modify its tree simultaneously.

Board source copies belong to `build/workspaces/<platform>/`, QEMU copies to
`build/workspaces/qemu-<arch>/`. All graph workspace locks are acquired in sorted
order and held until the invocation ends. First board builds in these workspaces
prepare fresh sources; old source directories are preserved. Final QEMU and rootfs
artifacts retain their architecture-specific `IMAGES/` names. Explicit mutable
source overrides outside the workspace are rejected. Read-only toolchains can
still be shared. Git clones/ref fetches share a locked bare download cache,
while each checkout has its own Git objects and patch state (no alternates or
hardlinks). Clearing the download cache does not invalidate existing checkouts.
New clones refresh the cached upstream default branch; pinned commit downloads
are reused. Download caching is separate from compiler/task cache policy.

Each target also holds `build/.locks/platform-<target>.lock` in the repository,
so different `BUILD_WORKSPACE_ROOT` values cannot bypass final-image exclusion.
The Bash workspace launcher uses the same sorted lock order. Target workspace
symlinks are rejected. Phytium Pi, ROC and EVM single-component commands include
Linux before rootfs injection instead of trusting a missing or stale image.
Manifest environment/argv types are validated before any task starts. On task
failure, remaining processes in its group are terminated before resources are
released; commands must not detach build workers into other process groups.
The `platform all` entry replaces itself with the scheduler so SIGTERM sent to
the entry PID reaches cancellation handling directly.

Old build directories are preserved. New architecture workspaces start cold;
there is no automatic move or deletion of user source caches. Stop builds before
running `cleanall`, which also removes default workspaces and their locks.

### Dependency graph contract

The shared rootfs composition flow embeds `ROOTFS_GUEST_COUNT` independent
guests, defaulting to two. The value must be a positive decimal integer. There
is no fixed count maximum; composition rejects counts whose guest images cannot
fit in the available host space before copying begins.
Names are zero-based, from `/guest/rootfs-<arch>-<type>-0.img` through
`-(count-1).img`. All start with identical contents from one test build and
occupy distinct regular files. Each must satisfy the guest free-space reserve.
Capacity planning includes every file, and platform/overlay injection protects
every configured name as well as rejecting legacy unnumbered names.
This applies to ext4 outer images and Orange Pi partitioned disk images;
BusyBox initramfs does not embed guests.

Rootfs test builds are explicit graph leaves rather than hidden work inside the
image node. Every selected plugin becomes a node such as
`tests.guest.cyclictest` or `tests.outer.ltp`. Per-scope overlay join nodes wait
for their plugin leaves, reject path/ancestor collisions, and publish one owned
directory. A separate clean-base node builds without tests. The final rootfs
node waits for the base and both joins, then produces the outer image and the
configured guests; platform composition waits for that image. All guests consume one guest-overlay result, so tests compile
once. Outer and guest installations remain separate nodes even for the same
plugin. Downloads and builder sources retain their locked
`ROOTFS_TEST_BUILD_ROOT` cache, while CPU budgets come from the global scheduler.
QEMU BusyBox/Alpine/Debian and the Orange Pi guest rootfs use this structure.
Orange Pi uses clean guest → guest-overlay injection → partitioned disk
composition. QEMU uses clean base + two overlays → multi-guest rootfs → platform
payload injection. BusyBox retains rollback-safe paired publication for its
initramfs and ext4 output. Validate the child graph with
`python3 scripts/tests/rootfs/rootfs-graph.py`; the real ext4 split is covered by
`bash scripts/tests/rootfs/rootfs-compose.sh`.

New adapters declare a graph instead of nesting worker pools. Invoke
`build_graph graph.json --log-dir logs/my-run` after sourcing the performance
helper, or `python3 scripts/lib/python/build-graph.py graph.json --log-dir logs/my-run`.
Use a new log directory for each invocation. Example manifest:

```json
{
  "cwd": "/absolute/repository",
  "locks": ["/absolute/build/workspaces/.locks/example.lock"],
  "env": {"BUILD_CACHE_DIR": "/absolute/build/.cache"},
  "tasks": [
    {"id": "prepare", "command": ["bash", "scripts/example.sh", "prepare"], "cpu_max": 1},
    {"id": "compile", "deps": ["prepare"], "command": ["bash", "scripts/example.sh", "compile"],
     "cpu_min": 1, "cpu_max": 8, "memory_mb": 2048, "resources": ["example.source"]}
  ]
}
```

IDs must be unique. Unknown dependencies, cycles and impossible resource
requests fail validation before commands execute. Commands are argv arrays;
use executable scripts that reconstruct their configuration, not serialized
shell functions. Nodes may override `cwd` and `env`. CPU minimum defaults to 1,
maximum to the total budget. Tasks must honor the compiler adapters and must
not create nested worker pools. The scheduler sets Make/CMake/Cargo budget
variables; explicit command-line concurrency can still defeat this contract.

`resources` names provide exclusion within one graph. Cross-process exclusion
requires `locks`, held for the entire invocation, acquired in sorted order and
not inherited by children. `memory_mb` is an estimate, enforced for admission
only when `BUILD_MEMORY_MB` is set; it is not an OS memory limit. Undeclared
memory defaults to zero. QEMU currently has no reliable per-task estimates.

Optional `cache_args` passes the existing `build_task` declaration arguments,
such as `["--input", "config", "--output", "objects/image"]`; the scheduler adds
the task name and command. Declare all inputs, patches, tools and outputs before
enabling whole-task caching. QEMU currently uses source validation and compiler
caches, without whole-node skipping.

Each run saves `graph.json`, `state.json`, `summary.log` and
`steps/<task-id>.log`. States are waiting, running, hit, success, failed,
blocked and cancelled. Failures print a log tail. SIGINT/SIGTERM terminates task
process groups before releasing workspaces. There is no automatic retry or
resume; reruns revalidate source and artifact caches. Test with
`python3 scripts/tests/build/build-graph.py` and `python3 scripts/tests/build/qemu-parallel.py`.

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

Run `bash scripts/tests/build/build-performance.sh` on Linux. It exercises actual
Make/CMake compilation, ccache hits, budget enforcement, task concurrency,
input/ref/patch/environment invalidation, output tampering, overlapping patches,
legacy adoption, local-edit preservation, and failed-patch retries.

`python3 scripts/tests/build/qemu-parallel.py` verifies real overlapping architecture
dispatch, isolated patches/configurations, shared downloads, concurrent limits,
failure aggregation, and single-architecture locking with local Git fixtures.
Terminal color routing is covered by `scripts/tests/build/build-review-regressions.py`.
