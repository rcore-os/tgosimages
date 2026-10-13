#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fixture="$work/repo"
mkdir -p "$fixture/scripts/platform" "$fixture/apps/ivc" "$work/"{sdk/scripts,kernel/include/config,objects/examples,bin,base}
cp -a "$root/scripts/lib" "$fixture/scripts/"
cp "$root/scripts/platform/ivc-linux.sh" "$fixture/scripts/platform/"
cp "$root/apps/ivc/ivc-roundtrip.c" "$fixture/apps/ivc/"
printf fixture >"$work/kernel/Makefile"
printf fixture >"$work/kernel/.config"
printf '6.1.99-existing\n' >"$work/kernel/include/config/kernel.release"
printf library >"$work/objects/libaxivc.a"
printf fixture >"$work/base/marker"
fakeroot bash -s -- "$work/base" "$work/base.cpio.gz" <<'BASE'
set -euo pipefail
cd "$1"
mkdir -p dev
mknod -m 0600 dev/console c 5 1
mknod -m 0600 dev/null c 1 3
chown 123:456 marker
find . -print0 | cpio --null --create --format=newc --quiet | gzip >"$2"
BASE
cat >"$work/sdk/scripts/build-orangepi-artifacts.sh" <<'SDK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${SKIP_KERNEL_PREPARE:-0}" >"$TEST_PREPARE_POLICY"
printf module >"$TEST_SDK/driver-module"
mkdir -p "$TEST_SDK/driver"
cp "$TEST_SDK/driver-module" "$TEST_SDK/driver/axvisor.ko"
for program in axivc-pub axivc-sub axivc-pingpong; do
    printf executable >"$BUILD_DIR/examples/$program"
done
SDK
cat >"$work/bin/aarch64-linux-musl-gcc" <<'CC'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    if [[ $1 == -o ]]; then printf executable >"$2"; exit 0; fi
    shift
done
exit 1
CC
cat >"$work/bin/file" <<'FILE'
#!/usr/bin/env bash
printf 'ELF 64-bit LSB executable, ARM aarch64, statically linked\n'
FILE
cat >"$work/bin/modinfo" <<'MODINFO'
#!/usr/bin/env bash
printf '6.1.99-existing SMP mod_unload aarch64\n'
MODINFO
cat >"$work/bin/make" <<'MAKE'
#!/usr/bin/env bash
printf 'kernelrelease invocation would reconfigure the prepared tree\n'
exit 2
MAKE
cat >"$work/bin/depmod" <<'DEPMOD'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -b && $3 == 6.1.99-existing ]]
tree="$2/lib/modules/$3"
[[ -s "$tree/extra/axvisor.ko" ]]
printf 'extra/axvisor.ko:\n' >"$tree/modules.dep"
printf index >"$tree/modules.dep.bin"
DEPMOD
chmod +x "$work/bin/"* "$work/sdk/scripts/build-orangepi-artifacts.sh"
export PATH="$work/bin:$PATH" LOG_CREATE_DEFAULT_FILE=0
export BUILD_WORK_DIR="$work/build" IVC_SDK_DIR="$work/sdk" IVC_BUILD_DIR="$work/objects"
export LINUX_KDIR="$work/kernel" IVC_LINUX_OUT="$work/output" BASE_INITRAMFS="$work/base.cpio.gz"
export TEST_SDK="$work/sdk" TEST_PREPARE_POLICY="$work/prepare-policy"
bash "$fixture/scripts/platform/ivc-linux.sh"
[[ $(cat "$TEST_PREPARE_POLICY") == 1 ]]
for path in lib/modules/6.1.99-existing/extra/axvisor.ko lib/modules/6.1.99-existing/modules.dep.bin lib/modules/axvisor.ko usr/bin/axivc-pub usr/bin/axivc-sub usr/bin/axivc-pingpong usr/bin/ivc-roundtrip initramfs.cpio; do
    [[ -s $IVC_LINUX_OUT/$path ]]
done
(cd "$work/base" && cpio -it <"$IVC_LINUX_OUT/initramfs.cpio" 2>/dev/null) | rg -q 'root/axvisor.ko'
printf 'PASS: Linux artifacts reuse prepared kernel configuration and release\n'
cpio --numeric-uid-gid -itv <"$IVC_LINUX_OUT/initramfs.cpio" >"$work/archive-list" 2>/dev/null
rg -q '^crw-------[[:space:]].*5,[[:space:]]+1.*dev/console$' "$work/archive-list"
rg -q '^crw-------[[:space:]].*1,[[:space:]]+3.*dev/null$' "$work/archive-list"
rg -q '123[[:space:]]+456.*marker$' "$work/archive-list"
rg -q '^-rwxr-xr-x[[:space:]]+[0-9]+[[:space:]]+0[[:space:]]+0.*root/ivc-roundtrip$' "$work/archive-list"
printf 'PASS: device nodes, ownership and program permissions survive initramfs repacking\n'


# A tool failure must identify the exact failing command in the step log.
printf '#!/bin/sh\nexit 17\n' >"$work/bin/aarch64-linux-musl-gcc"
status=0
bash "$fixture/scripts/platform/ivc-linux.sh" >"$work/failure.log" 2>&1 || status=$?
[[ $status == 17 ]]
rg -q 'IVC Linux failed \(status=17,' "$work/failure.log"
rg -q 'gcc' "$work/failure.log"
printf 'PASS: compiler failure reports command and preserves exit status\n'
