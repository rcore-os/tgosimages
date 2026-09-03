# Rootfs Test Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build extensible outer/guest test overlays from plugins, branch every ext4 rootfs from one clean base, and embed the compact guest image under the final outer rootfs `/guest` while leaving BusyBox initramfs outside this scheme.

**Architecture:** `scripts/rootfs-tests/build.sh` discovers independent test plugins and merges their filesystem-rooted output into one collision-checked overlay. Each rootfs builder first creates a clean ext4 image, then a common composer creates outer and guest copies, applies independently selected overlays, compacts the guest, grows the outer from measured payload sizes, and embeds the guest image. QEMU continues to inject platform payloads afterward, so they enter only the outer image.

**Tech Stack:** Bash, Docker/multi-arch Alpine build containers, GNU make, `debugfs`, `dumpe2fs`, `e2fsck`, `resize2fs`, `readelf`, `file`, `sha256sum`.

---

The user explicitly requested no commits. Every task therefore ends with a focused diff and test checkpoint instead of a `git commit` step. Do not add or stage the unrelated `patches/qemu/0003-enable-virtio-mmio.patch`.

## File map

**Create**

- `scripts/rootfs-tests/build.sh` — plugin discovery, capability filtering, defaults, collision-safe overlay merge.
- `scripts/rootfs-tests/lib/common.sh` — checked downloads, architecture mapping, ELF validation, per-cache locking.
- `scripts/rootfs-tests/plugins/cyclictest.sh` — rt-tests/cyclictest source and build adapter.
- `scripts/rootfs-tests/plugins/lmbench.sh` — LMBench source and build adapter.
- `scripts/rootfs-tests/plugins/iozone.sh` — IOZone source and build adapter.
- `scripts/rootfs-tests/plugins/ltp.sh` — Alpine outer-only LTP adapter extracted from the current Alpine implementation.
- `scripts/lib/rootfs-compose.sh` — ext4 measurement, growth, compaction, cloning and outer/guest composition.
- `scripts/tests/rootfs-test-plugins.sh` — framework tests using fake plugins; no network required.
- `scripts/tests/rootfs-compose.sh` — small ext4 integration tests for capacity and nesting.
- `scripts/tests/rootfs-nested-content.sh` — final image content/ELF verification.

**Modify**

- `scripts/rootfs/alpine.sh` — stop installing LTP before the branch; call the common composer after producing a clean image.
- `scripts/rootfs/busybox.sh` — compose only the ext4 output; keep `.cpio.gz` unchanged by this feature.
- `scripts/rootfs/debian.sh` — call the common composer after producing the clean ext4 image.
- `scripts/platform/qemu.sh` — parse and forward test/space options while retaining platform-only post-build injection.
- `build.sh` — document/forward rootfs test selection options.
- `scripts/tests/alpine-ltp-content.sh` — assert LTP is present only in outer Alpine and absent from its nested guest image.
- `README.md`, `README_CN.md` — document plugins, defaults, nested paths and capacity behavior.

## Fixed upstream inputs

- cyclictest: `rt-tests-2.10.tar.xz`, SHA-256
  `1d1184ab0b578a91c586ea9ed0c50e4b42f9f038d5465eae15beb14751e88ba6`,
  from `https://www.kernel.org/pub/linux/utils/rt-tests/rt-tests-2.10.tar.xz`.
- LMBench: Intel commit `5a386c1c32a84898151dade7754031813e33994e`, archive SHA-256
  `febf1d63221ee6dba60877bce0943ce268231ad9b4d5804b3fdfa614bf5c6459`,
  from the exact endpoint
  `https://github.com/intel/lmbench/archive/5a386c1c32a84898151dade7754031813e33994e.tar.gz`.
- IOZone: `iozone3_511.tgz`, SHA-256
  `1aa00bc3cd627ec46ca17aa78c8fabd143d32025155c741f49392b1bdd776298`,
  from `https://iozone.org/src/current/iozone3_511.tgz`.
- LTP: retain the repository's current `20260529` source URL, filters and build
  flags; pin the cached archive SHA-256 to
  `685d83c6e370ac09201fb79593412f868fe031ee2890e204b5727fedcf51fb47`.

Do not use mutable `latest` or branch archives in implementation. Allow environment-variable URL overrides for mirrors, but always verify against the pinned checksum unless an explicit checksum override accompanies the URL override.

### Task 1: Plugin contract, discovery, defaults, and collision checks

**Files:**

- Create: `scripts/rootfs-tests/build.sh`
- Create: `scripts/rootfs-tests/lib/common.sh`
- Create: `scripts/tests/rootfs-test-plugins.sh`

- [ ] **Step 1: Write framework tests with temporary fake plugins**

The test creates an isolated `ROOTFS_TEST_PLUGIN_DIR` containing executable plugins with this contract:

```bash
case "${1:-}" in
    describe)
        printf '%s\n' \
            'name=fake-a' \
            'arches=aarch64,riscv64,x86_64,loongarch64' \
            'rootfs=busybox,alpine,debian' \
            'scopes=guest'
        ;;
    build)
        # Parse --arch, --rootfs, --scope, --output.
        mkdir -p "${output}/guest-tests/fake-a"
        printf 'fake-a\n' >"${output}/guest-tests/fake-a/payload"
        ;;
    *) exit 2 ;;
esac
```

Cover these cases in `scripts/tests/rootfs-test-plugins.sh`:

- explicit `fake-a,fake-b` merges both outputs;
- duplicate names in the selection run once;
- `all` selects only plugins whose `describe` capabilities match arch/rootfs/scope;
- `none` creates an empty overlay successfully;
- unknown plugin and unsupported explicit selection return nonzero;
- two plugins writing the same relative path return nonzero and do not publish a partial overlay;
- a malformed `describe` response returns nonzero;
- defaults resolve to `ltp` only for Alpine outer and to
  `cyclictest,lmbench,iozone` for all supported guest ext4 rootfs types.

- [ ] **Step 2: Run the test and verify the framework is missing**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
```

Expected: FAIL because `scripts/rootfs-tests/build.sh` does not exist.

- [ ] **Step 3: Implement strict plugin discovery and capability parsing**

Implement `build.sh` with:

```text
build.sh build --arch ARCH --rootfs TYPE --scope SCOPE \
  --tests LIST --output DIR
build.sh defaults --rootfs TYPE --scope SCOPE
build.sh list --arch ARCH --rootfs TYPE --scope SCOPE
```

Rules:

- valid arch: `aarch64|riscv64|x86_64|loongarch64`;
- valid rootfs: `busybox|alpine|debian`;
- valid scope: `outer|guest`;
- discover only executable `*.sh` directly below
  `${ROOTFS_TEST_PLUGIN_DIR:-scripts/rootfs-tests/plugins}`;
- reject duplicate declared plugin names;
- parse only the four exact `key=value` lines from `describe`; reject missing or unknown keys;
- execute every plugin into its own empty temporary directory;
- build a sorted relative-path inventory before merge;
- allow multiple plugins to claim the same directory ancestor (for example all
  guest plugins share `guest-tests/`), but reject duplicate files/symlinks,
  file-vs-directory conflicts, and cases where a file or symlink blocks another
  plugin's descendant path;
- merge into `${output}.tmp.$$`, then rename to `output` only after all plugins pass;
- default lists live in this framework, not in the rootfs composer.

Add reusable helpers to `common.sh`:

```bash
rootfs_test_csv_contains VALUE CSV
rootfs_test_expected_machine ARCH
rootfs_test_cross_prefix ARCH
rootfs_test_download_checked URL SHA256 DEST
rootfs_test_validate_elf ARCH FILE
```

Never use `eval` or source plugin-provided `describe` output.

- [ ] **Step 4: Run framework tests**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
bash -n scripts/rootfs-tests/build.sh scripts/rootfs-tests/lib/common.sh
```

Expected: all plugin tests print PASS; syntax checks return zero.

- [ ] **Step 5: Inspect the focused diff**

Run:

```bash
git diff --check
git diff -- scripts/rootfs-tests/build.sh scripts/rootfs-tests/lib/common.sh scripts/tests/rootfs-test-plugins.sh
```

Expected: no whitespace errors; only framework/test files appear.

### Task 2: Implement cyclictest, LMBench, and IOZone guest plugins

**Files:**

- Create: `scripts/rootfs-tests/plugins/cyclictest.sh`
- Create: `scripts/rootfs-tests/plugins/lmbench.sh`
- Create: `scripts/rootfs-tests/plugins/iozone.sh`
- Modify: `scripts/tests/rootfs-test-plugins.sh`

- [ ] **Step 1: Add metadata and mocked-build tests for all three plugins**

Assert each `describe` reports:

```text
arches=aarch64,riscv64,x86_64,loongarch64
rootfs=busybox,alpine,debian
scopes=guest
```

Add a `ROOTFS_TEST_OFFLINE_FIXTURE_DIR` hook used only by tests. With tiny fixture Makefiles, verify output paths:

```text
guest-tests/cyclictest/cyclictest
guest-tests/lmbench/bin/<lmbench executables>
guest-tests/lmbench/scripts/<runtime scripts>
guest-tests/iozone/iozone
```

Assert no plugin creates `run-all.sh`.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
```

Expected: FAIL because the three real plugin scripts do not exist.

- [ ] **Step 3: Implement checked source acquisition and isolated caches**

Each plugin must:

- call `rootfs_test_download_checked` with the fixed input above;
- extract into `build/rootfs-tests/sources/<name>-<version>` through a temporary directory and atomic rename;
- build in `build/rootfs-tests/work/<name>/<version>/<arch>/<rootfs>`;
- serialize creation of a shared download/source cache using `flock`;
- honor the offline fixture hook without network access in unit tests.

- [ ] **Step 4: Implement architecture-native static builds in Alpine containers**

Use the repository's Alpine 3.23 multi-arch Docker-image pattern and platform mapping:

```text
aarch64     -> linux/arm64/v8
riscv64     -> linux/riscv64
x86_64      -> linux/amd64
loongarch64 -> linux/loong64
```

Build inside the target-architecture container rather than running target binaries on the host. Install build-only dependencies in the container. For cyclictest, build only the `cyclictest` target with `no_libcpupower=1` and static libnuma; for LMBench, pass `OS=<arch>-linux-gnu`, an explicit compiler and static link flags; for IOZone, build the Linux target with explicit compiler and static flags.

After each build, require:

```bash
readelf -h FILE                 # correct ELF64 machine
readelf -l FILE                 # no INTERP program header
readelf -d FILE                 # no NEEDED entries
test -x FILE
```

If an upstream Makefile cannot honor static flags, add the smallest version-scoped patch under `patches/rootfs-tests/<name>/`; do not weaken validation or bundle an undeclared host library.

- [ ] **Step 5: Run offline tests, then one real x86_64 build per plugin**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
bash scripts/rootfs-tests/build.sh build \
  --arch x86_64 --rootfs alpine --scope guest \
  --tests cyclictest,lmbench,iozone \
  --output /tmp/tgos-rootfs-tests-x86_64
find /tmp/tgos-rootfs-tests-x86_64 -type f -maxdepth 5 -print | sort
```

Expected: unit tests pass; real build succeeds; files are rooted below
`guest-tests/`; no `run-all.sh` exists.

- [ ] **Step 6: Inspect the focused diff**

Run `git diff --check` and inspect only the three plugins, any necessary version-scoped patches, and their tests.

### Task 3: Extract Alpine LTP as an outer-only plugin

**Files:**

- Create: `scripts/rootfs-tests/plugins/ltp.sh`
- Modify: `scripts/rootfs/alpine.sh`
- Modify: `scripts/rootfs/alpine-ltp.Dockerfile` only if the plugin needs a neutral path/name
- Modify: `scripts/tests/alpine-ltp-content.sh`
- Modify: `scripts/tests/rootfs-test-plugins.sh`

- [ ] **Step 1: Add failing LTP capability and overlay tests**

Assert `ltp.sh describe` is exactly limited to:

```text
name=ltp
arches=aarch64,riscv64,x86_64,loongarch64
rootfs=alpine
scopes=outer
```

Use a fixture source tree to assert the plugin output is rooted at `opt/ltp`, retains `timer_create02`, and omits the current `fmtmsg`, `timer_create01`, and `timer_create03` exclusions.

- [ ] **Step 2: Run the tests and verify failure**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
```

Expected: FAIL because `ltp.sh` is missing and Alpine still owns the build directly.

- [ ] **Step 3: Move LTP build responsibility without changing content**

Move the constants and source/build/install logic currently in
`scripts/rootfs/alpine.sh` into `plugins/ltp.sh`. Change its destination from a full rootfs directory to an empty overlay root so the existing `/opt/ltp` installation becomes `OUTPUT/opt/ltp`.

Route the LTP archive through `rootfs_test_download_checked` using SHA-256
`685d83c6e370ac09201fb79593412f868fe031ee2890e204b5727fedcf51fb47`.
An alternate `ALPINE_LTP_URL` must still use that digest unless accompanied by
an explicit `ALPINE_LTP_SHA256` override.

Keep these behaviors byte/content compatible:

- LTP version `20260529`;
- prefix `/opt/ltp`;
- Alpine/musl Docker build;
- existing directory and testcase filters;
- `Version`, `runtest/syscalls`, `runtest/sched`, and installed binaries.

Remove `alpine_install_ltp_tests` from the common Alpine base-content phase. Do not yet change final Alpine behavior; Task 5 will apply the default outer overlay after the clean image is packed.

- [ ] **Step 4: Run plugin tests and a real x86_64 overlay build**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
bash scripts/rootfs-tests/build.sh build \
  --arch x86_64 --rootfs alpine --scope outer --tests ltp \
  --output /tmp/tgos-ltp-outer
test -x /tmp/tgos-ltp-outer/opt/ltp/testcases/bin/timer_create02
test ! -e /tmp/tgos-ltp-outer/opt/ltp/testcases/bin/timer_create01
```

Expected: all checks pass.

- [ ] **Step 5: Inspect the focused diff**

Run `git diff --check` and compare moved constants/filter logic against the original Alpine implementation to ensure no implicit LTP feature was dropped.

### Task 4: Add tested ext4 sizing and composition primitives

**Files:**

- Create: `scripts/lib/rootfs-compose.sh`
- Create: `scripts/tests/rootfs-compose.sh`
- Modify: `scripts/lib/rootfs.sh` only to reuse/export existing debugfs injection helpers cleanly

- [ ] **Step 1: Write failing small-image integration tests**

Create 32 MiB ext4 images under a `mktemp -d /tmp/rootfs-compose.XXXXXX` directory. Test:

- `rootfs_ext4_free_bytes IMAGE` matches `dumpe2fs` block accounting;
- `rootfs_overlay_apparent_bytes DIR` counts sparse files by apparent size;
- `rootfs_ensure_ext4_capacity IMAGE PAYLOAD_BYTES RESERVE_BYTES` grows before injection and leaves at least the requested free bytes afterward;
- `rootfs_compact_ext4 IMAGE 16M` runs `e2fsck`, shrinks to the filesystem block count, regrows by 16 MiB and leaves at least that reserve;
- malformed sizes, non-ext images and dirty/unrepairable images fail;
- composing from a base produces distinct outer and guest files and never modifies the base;
- the guest contains fixture `/guest-tests/fake/payload`;
- the outer contains `/guest/rootfs-x86_64-busybox.img` and an outer-only fixture;
- the extracted nested image contains no outer fixture and no `/guest/rootfs-*.img` recursion;
- a pre-existing colliding nested-image path fails before modifying the output.

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
bash scripts/tests/rootfs-compose.sh
```

Expected: FAIL because `scripts/lib/rootfs-compose.sh` is absent.

- [ ] **Step 3: Implement byte parsing and ext4 measurement**

Provide public functions:

```bash
rootfs_parse_size_bytes VALUE
rootfs_ext4_free_bytes IMAGE
rootfs_overlay_apparent_bytes DIRECTORY
rootfs_ensure_ext4_capacity IMAGE PENDING_BYTES RESERVE_BYTES
rootfs_compact_ext4 IMAGE RESERVE_BYTES
rootfs_compose_test_images BASE OUTER_OVERLAY GUEST_OVERLAY \
    OUTER_GUEST_DIR ARCH ROOTFS_TYPE GUEST_FREE OUTER_FREE OUTPUT
rootfs_inject_outer_payload_atomic IMAGE GUEST_SOURCE OVERLAY_SOURCE \
    PROTECTED_GUEST_BASENAME OUTER_FREE
```

Use integer byte/block calculations from `dumpe2fs -h`; round growth to 4 MiB. For a pending payload, require enough free blocks for its full apparent length, requested post-injection reserve, and 5% metadata/headroom. Run `e2fsck -pf` before growth and accept only its documented clean/corrected exit statuses, then `truncate` and `resize2fs`.

For compaction, run `e2fsck -fy`, `resize2fs -M`, read the new filesystem block count, truncate the regular image file to that exact byte length, then grow and resize by the requested reserve. Verify the resulting free-block count rather than trusting command success alone.
If metadata consumption leaves less than the requested reserve, repeat measured
growth in 4 MiB increments until the postcondition is satisfied.

- [ ] **Step 4: Implement atomic outer/guest composition**

The composition function must:

1. copy the clean base to separate outer/guest temp files with `cp --reflink=auto --sparse=always`;
2. pre-grow guest from the guest overlay's apparent size;
3. inject guest overlay with `rootfs_inject_overlay_stage`;
4. compact guest and add `GUEST_FREE`;
5. pre-grow and inject outer overlay;
6. construct a temporary filesystem-rooted overlay containing any existing
   builder `--guest` payload at `guest/` plus
   `guest/rootfs-ARCH-TYPE.img`; reject a basename collision before copying;
7. pre-grow outer using only this not-yet-injected overlay and `OUTER_FREE`;
8. inject it and run final `e2fsck -fn` checks;
9. atomically rename the completed outer temp file to `OUTPUT`;
10. clean all temps on failure while preserving any old `OUTPUT`.

Do not accept `.cpio.gz` as `BASE` or `OUTPUT`.

`rootfs_inject_outer_payload_atomic` is the safe post-composition path used by
QEMU: copy the existing outer image to a same-directory temporary file, reject
`GUEST_SOURCE/PROTECTED_GUEST_BASENAME`, compute and grow for only the pending
guest/overlay payloads, inject them, verify `OUTER_FREE` and `e2fsck -fn`, then
atomically replace the original. On failure, preserve the original image.

- [ ] **Step 5: Run ext4 integration tests**

Run:

```bash
bash scripts/tests/rootfs-compose.sh
git diff --check
```

Expected: all small-image cases pass without root privileges.

### Task 5: Integrate composition into all ext4 rootfs builders

**Files:**

- Modify: `scripts/rootfs/busybox.sh`
- Modify: `scripts/rootfs/alpine.sh`
- Modify: `scripts/rootfs/debian.sh`
- Modify: `scripts/lib/rootfs-compose.sh`
- Create: `scripts/tests/rootfs-builder-options.sh`

- [ ] **Step 1: Write failing parser/default tests**

For each builder, source it with side effects mocked and verify parsing of:

```text
--outer-tests <list>
--guest-tests <list>
--guest-free-size <size>
--outer-free-size <size>
```

Assert defaults come from `scripts/rootfs-tests/build.sh defaults`, not duplicated case statements. Assert invalid sizes and unsupported explicit plugins fail before downloads or image writes.

Assert BusyBox passes only `rootfs-ARCH-busybox.img` to the composer; its initramfs checksum before/after a mocked composition remains identical.

Also assert existing `--guest DIR` semantics are split deliberately: the files
enter the outer ext4 `/guest` only, never the clean base or nested guest image;
BusyBox initramfs continues to receive the same `--guest` directory as before.

- [ ] **Step 2: Run parser tests and verify failure**

Run:

```bash
bash scripts/tests/rootfs-builder-options.sh
```

Expected: FAIL because the options/composer calls do not exist.

- [ ] **Step 3: Add common option parsing and overlay preparation**

Factor repeated option validation/preparation into `rootfs-compose.sh` so each builder only supplies `ARCH`, rootfs type, clean image path, and final output path. Defaults:

```text
outer: Alpine=ltp, BusyBox=none, Debian=none
guest: cyclictest,lmbench,iozone
guest free: 256M
outer free: 256M
```

The common preparation function calls `scripts/rootfs-tests/build.sh` twice into isolated outer/guest overlay directories.

- [ ] **Step 4: Move each builder's publish boundary after composition**

- BusyBox: build the common tree without `--guest`; add `--guest` only while
  packing `.cpio.gz`, then remove that staged directory before packing the clean
  ext4 base. Pass the same source directory to the composer as outer-only guest
  content. This preserves initramfs behavior while keeping the nested ext4 clean.
- Alpine: remove `alpine_copy_guest_dir` from the common tree phase, pack the
  configured distro/default-package/startup tree before any LTP, and pass
  `ALPINE_GUEST_DIR` to the composer as outer-only `/guest` content. The LTP
  plugin enters only outer and guest plugins enter only the nested image.
- Debian: stop mounting/copying `/guest-src` during debootstrap/base packing;
  pack a clean image and pass `DEBIAN_GUEST_DIR` to the composer as outer-only
  `/guest` content.

Never rebuild a new final image from the previous final image. Clean commands must remove only documented final outputs and stale task-owned temporary patterns.

- [ ] **Step 5: Run option, plugin, and composition tests**

Run:

```bash
bash scripts/tests/rootfs-builder-options.sh
bash scripts/tests/rootfs-test-plugins.sh
bash scripts/tests/rootfs-compose.sh
bash -n scripts/rootfs/{busybox,alpine,debian}.sh
```

Expected: all pass.

- [ ] **Step 6: Build one complete x86_64 BusyBox image**

Run:

```bash
scripts/rootfs/busybox.sh x86_64 \
  --out_dir /tmp/tgos-rootfs-integration \
  --outer-tests none \
  --guest-tests cyclictest,lmbench,iozone \
  --guest-free-size 256M \
  --outer-free-size 256M
```

Expected: ext4 output contains a nested BusyBox image and guest tests; initramfs contains neither nested image nor `/guest-tests`.

### Task 6: Preserve QEMU platform injection and forward configuration

**Files:**

- Modify: `scripts/platform/qemu.sh`
- Modify: `build.sh`
- Create: `scripts/tests/qemu-rootfs-test-options.sh`

- [ ] **Step 1: Add failing QEMU option-routing tests**

Mock OS and rootfs commands and assert:

- `--outer-tests`, `--guest-tests`, `--guest-free-size`, and
  `--outer-free-size` go only to selected rootfs builders;
- unrelated existing build arguments continue to go to OS builders;
- defaults are not redundantly appended by QEMU;
- `qemu_rootfs_inject_platform_dir` adds platform files to outer images but does not open or alter the nested guest image;
- a platform source whose top-level name equals
  `rootfs-ARCH-TYPE.img` is rejected before any outer image is modified;
- each ext4 outer image is pre-grown for the full pending platform/IVC payload,
  atomically injected, checked with `e2fsck`, and still has `OUTER_FREE` afterward;
- BusyBox initramfs still receives only the existing platform payload;
- aarch64 Alpine still receives the IVC overlay only in outer.

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
bash scripts/tests/qemu-rootfs-test-options.sh
```

Expected: FAIL because QEMU currently forwards no rootfs test options.

- [ ] **Step 3: Split rootfs arguments from OS arguments**

Extend `qemu_rootfs_parse_args` with a `ROOTFS_BUILD_ARGS` array. Consume the four rootfs-only options with strict arity checks and retain all other arguments in `BUILD_ARGS`. When creating explicit parallel command strings, shell-quote every rootfs argument with `printf '%q'`; do not concatenate untrusted raw values.

Keep `qemu_rootfs_inject_platform_dir` after the parallel rootfs build. Since the
nested guest image is already present, its staging directory must add/replace
only the existing outer `/guest/<os>` paths and the aarch64 Alpine IVC overlay;
it must not restage or regenerate `/guest/rootfs-*.img`.

Before touching any ext4 output, reject a top-level platform artifact named
`rootfs-${ARCH}-${rootfs_builder}.img`. For every ext4 rootfs, call
`rootfs_inject_outer_payload_atomic` with the complete pending platform staging
tree, optional IVC overlay, protected nested basename, and configured outer
reserve. This gives QEMU injection the same capacity preflight, no-partial-write,
post-injection reserve, and final filesystem check guarantees as initial
composition. Continue using the existing cpio injection helper for BusyBox
initramfs; ext4 capacity rules do not apply to it.

- [ ] **Step 4: Update help text**

Document the four options in `scripts/platform/qemu.sh` and the top-level examples in `build.sh`. Explicitly state that BusyBox initramfs excludes nested rootfs and guest tests.

- [ ] **Step 5: Run routing and syntax tests**

Run:

```bash
bash scripts/tests/qemu-rootfs-test-options.sh
bash -n build.sh scripts/platform/qemu.sh
git diff --check
```

Expected: all pass.

### Task 7: Verify final nested content, isolation, architecture, and space

**Files:**

- Create: `scripts/tests/rootfs-nested-content.sh`
- Modify: `scripts/tests/alpine-ltp-content.sh`

- [ ] **Step 1: Write the content verifier**

Accept `--image-dir`, optional `--arch`, and optional `--rootfs`. For each selected outer ext4 image:

1. use `debugfs` to assert `/guest/rootfs-ARCH-TYPE.img` exists;
2. dump it to a temporary file;
3. run `e2fsck -fn` on the dumped image;
4. assert `/guest-tests/cyclictest/cyclictest`, LMBench runtime files, and
   `/guest-tests/iozone/iozone` exist in the nested image;
5. dump representative ELF files and validate `ELF64` plus the expected machine;
6. assert the nested image does not contain `/opt/ltp`, outer platform directories, or another `/guest/rootfs-*.img`;
7. read `dumpe2fs` free blocks and assert configured guest reserve;
8. assert outer free blocks meet configured outer reserve.

For Alpine outer, retain all existing LTP assertions. Add an explicit dump/check proving nested Alpine has no `/opt/ltp`.

For BusyBox initramfs, unpack to a temp directory with fakeroot/cpio and assert neither `/guest-tests` nor `/guest/rootfs-*.img` exists; retain any existing platform-payload expectations.

- [ ] **Step 2: Run the verifier against the Task 5 BusyBox artifact**

Run:

```bash
bash scripts/tests/rootfs-nested-content.sh \
  --image-dir /tmp/tgos-rootfs-integration \
  --arch x86_64 --rootfs busybox
```

Expected: PASS.

- [ ] **Step 3: Build and verify x86_64 Alpine**

Run:

```bash
scripts/rootfs/alpine.sh x86_64 --out_dir /tmp/tgos-rootfs-integration
bash scripts/tests/rootfs-nested-content.sh \
  --image-dir /tmp/tgos-rootfs-integration \
  --arch x86_64 --rootfs alpine
bash scripts/tests/alpine-ltp-content.sh \
  --image-dir /tmp/tgos-rootfs-integration --arch x86_64
```

If `alpine-ltp-content.sh` does not currently accept `--arch`, add that backwards-compatible filter as part of this task.

Expected: outer Alpine contains LTP; nested Alpine contains only selected guest tests and no LTP.

- [ ] **Step 4: Measure raw and release-compressed size**

Run:

```bash
ls -lh /tmp/tgos-rootfs-integration/rootfs-x86_64-{busybox,alpine}.img
xz -T0 -k -f /tmp/tgos-rootfs-integration/rootfs-x86_64-alpine.img
ls -lh /tmp/tgos-rootfs-integration/rootfs-x86_64-alpine.img.xz
```

Record the measured raw, nested, and compressed sizes in the task notes. Do not impose a guessed compressed-size pass threshold; correctness and configured free space are hard requirements.

### Task 8: Documentation and full verification

**Files:**

- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: all new/changed test scripts if final verification reveals defects

- [ ] **Step 1: Document the final interface and layout**

Cover:

- plugin `describe`/`build` contract;
- fixed default outer/guest selections and how to override them;
- adding a new plugin without editing the composer;
- `/guest-tests/<plugin>` convention and absence of `run-all.sh`;
- `/guest/rootfs-<arch>-<type>.img` nested path;
- 256 MiB default guest/outer reserves and size override examples;
- raw size versus release-compressed size;
- BusyBox ext4 participation and initramfs exclusion;
- Alpine LTP outer-only guarantee.

- [ ] **Step 2: Run all fast tests**

Run:

```bash
bash scripts/tests/rootfs-test-plugins.sh
bash scripts/tests/rootfs-compose.sh
bash scripts/tests/rootfs-builder-options.sh
bash scripts/tests/qemu-rootfs-test-options.sh
bash scripts/tests/starry-release-smoke.sh
git diff --check
```

Expected: all pass.

- [ ] **Step 3: Run syntax checks on every changed shell script**

Run:

```bash
bash -n \
  build.sh \
  scripts/platform/qemu.sh \
  scripts/lib/rootfs.sh \
  scripts/lib/rootfs-compose.sh \
  scripts/rootfs/{busybox,alpine,debian}.sh \
  scripts/rootfs-tests/build.sh \
  scripts/rootfs-tests/lib/common.sh \
  scripts/rootfs-tests/plugins/*.sh \
  scripts/tests/{rootfs-test-plugins,rootfs-compose,rootfs-builder-options,qemu-rootfs-test-options,rootfs-nested-content,alpine-ltp-content}.sh
```

Expected: zero exit status.

- [ ] **Step 4: Run the supported architecture build matrix**

Run each architecture separately so failures are attributable:

```bash
./build.sh platform qemu-aarch64 linux
./build.sh platform qemu-riscv64 linux
./build.sh platform qemu-x86_64 linux
./build.sh platform qemu-loongarch64 linux
```

Expected rootfs types follow current defaults: BusyBox/Alpine/Debian except LoongArch64, which remains BusyBox/Alpine. For every produced ext4 image, run `scripts/tests/rootfs-nested-content.sh`. Run the existing QEMU boot/smoke path for at least x86_64 outer and one extracted nested guest image.

- [ ] **Step 5: Final scope and safety review**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Expected: no generated archives, build caches, images, logs, `/tmp` files, or unrelated QEMU patch changes are included. Leave all intended source, test, documentation, spec, and plan files unstaged and uncommitted, per the user's instruction.
