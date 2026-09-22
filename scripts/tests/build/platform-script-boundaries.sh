#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/rtthread/bsp/phytium/aarch64" "$fixture/sdk" "$fixture/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$PWD" > "$BOUNDARY_PROBE"\n' > "$fixture/bin/scons"
chmod +x "$fixture/bin/scons"
BOUNDARY_PROBE="$fixture/rtthread-path" BUILD_CACHE=0 PATH="$fixture/bin:$PATH" \
    bash "$root/scripts/os/rtthread.sh" phytiumpi --src-dir "$fixture/rtthread" \
    --images-dir "$fixture/images" -c
[[ $(<"$fixture/rtthread-path") == "$fixture/rtthread/bsp/phytium/aarch64" ]]

source "$root/scripts/lib/utils.sh"
source "$root/scripts/platform/phytiumpi.sh"
LINUX_SRC_DIR="$fixture/phytiumpi"
mkdir -p "$LINUX_SRC_DIR/output/build/skeleton-custom/"{dev/pts,dev,proc,sys}
mkdir -p "$LINUX_SRC_DIR/output/host/aarch64-test/sysroot/sys/host-devices"
printf polluted >"$LINUX_SRC_DIR/output/host/aarch64-test/sysroot/sys/host-devices/value"
declare -A boundary_mounts=(
    ["$LINUX_SRC_DIR/output/build/skeleton-custom/dev/pts"]=1
    ["$LINUX_SRC_DIR/output/build/skeleton-custom/proc"]=1
    ["$LINUX_SRC_DIR/output/build/skeleton-custom/sys"]=1
)
mountpoint() {
    [[ $1 == -q && ${boundary_mounts[$2]:-0} == 1 ]]
}
sudo() {
    [[ $1 == umount && $2 == -R && $3 == -- && $# -eq 4 ]]
    printf '%s\n' "$4" >>"$fixture/phytium-unmounts"
    boundary_mounts[$4]=0
}
phytiumpi_unmount_rootfs_mounts
[[ $(wc -l <"$fixture/phytium-unmounts") -eq 3 ]]
[[ ${boundary_mounts["$LINUX_SRC_DIR/output/build/skeleton-custom/dev/pts"]} == 0 ]]
[[ ${boundary_mounts["$LINUX_SRC_DIR/output/build/skeleton-custom/proc"]} == 0 ]]
[[ ${boundary_mounts["$LINUX_SRC_DIR/output/build/skeleton-custom/sys"]} == 0 ]]
[[ ! -e $LINUX_SRC_DIR/output/host/aarch64-test/sysroot/sys ]]
unset -f mountpoint sudo

phytium_source_images="$fixture/phytium-source-images"
phytium_linux_images="$fixture/phytium-linux-images"
phytium_rootfs_images="$fixture/phytium-rootfs-images"
mkdir -p "$phytium_source_images" "$phytium_linux_images"
printf stale >"$phytium_linux_images/sdcard.img"
printf stale >"$phytium_linux_images/rootfs.ext2"
for artifact in fip-all.bin fitImage kernel.its phytiumpi_firefly.dtb sdcard.img rootfs.ext2; do
    printf '%s\n' "$artifact" >"$phytium_source_images/$artifact"
done
printf 'phytium kernel\n' | gzip >"$phytium_source_images/Image.gz"
phytiumpi_publish_linux_artifacts \
    "$phytium_source_images" "$phytium_linux_images" "$phytium_rootfs_images"
[[ $(<"$phytium_linux_images/Image") == 'phytium kernel' ]]
cmp "$phytium_linux_images/Image" "$phytium_linux_images/phytiumpi"
[[ $(<"$phytium_linux_images/phytiumpi.dtb") == phytiumpi_firefly.dtb ]]
[[ ! -e $phytium_linux_images/sdcard.img ]]
[[ ! -e $phytium_linux_images/rootfs.ext2 ]]
cmp "$phytium_source_images/sdcard.img" "$phytium_rootfs_images/phytiumpi.img"
cmp "$phytium_source_images/rootfs.ext2" "$phytium_rootfs_images/phytiumpi.rootfs.ext2"
[[ ! -e $phytium_linux_images/phytiumpi_firefly.dtb ]]
! find "$phytium_linux_images" -maxdepth 1 -name '.Image.tmp.*' -print -quit | grep -q .

printf '#!/bin/sh\ncommand -v python2 > "$BOUNDARY_PROBE"\ncommand -v python > "$BOUNDARY_PYTHON_PROBE"\ncat >/dev/null\n' > "$fixture/sdk/build.sh"
chmod +x "$fixture/sdk/build.sh"
existing_python=$(command -v python || true)
assert_python_path() {
    local resolved
    resolved=$(<"$1")
    if [[ -n $existing_python ]]; then
        [[ $resolved == "$existing_python" ]]
    else
        [[ $resolved == *tgosimages-python2* ]]
    fi
}
BOUNDARY_PROBE="$fixture/firefly-python2" BOUNDARY_PYTHON_PROBE="$fixture/firefly-python" \
    bash "$root/scripts/lib/firefly-sdk-build.sh" "$fixture/sdk" all
[[ $(<"$fixture/firefly-python2") == *tgosimages-python2* ]]
assert_python_path "$fixture/firefly-python"

mkdir -p "$fixture/evm sdk"
printf '#!/usr/bin/env bash\nprintf "%%s\\0" "$@" >"$BOUNDARY_REMOTE_PROBE"\n' \
    >"$fixture/evm sdk/build.sh"
chmod +x "$fixture/evm sdk/build.sh"
source "$root/scripts/platform/evm3588.sh"
ssh() {
    [[ $1 == fixture-host && $# -eq 2 ]]
    bash -c "$2"
}
BOUNDARY_REMOTE_PROBE="$fixture/evm-remote-argv"
export BOUNDARY_REMOTE_PROBE
run_evm3588_remote_sdk fixture-host "$fixture/evm sdk" \
    'argument with spaces' 'semi;colon' '*literal*'
mapfile -d '' -t remote_argv <"$BOUNDARY_REMOTE_PROBE"
[[ ${#remote_argv[@]} -eq 3 ]]
[[ ${remote_argv[0]} == 'argument with spaces' ]]
[[ ${remote_argv[1]} == 'semi;colon' ]]
[[ ${remote_argv[2]} == '*literal*' ]]
BOUNDARY_PROBE="$fixture/firefly-python2" BOUNDARY_PYTHON_PROBE="$fixture/firefly-python" \
    bash -s -- "$fixture/sdk" all < "$root/scripts/lib/firefly-sdk-build.sh"
assert_python_path "$fixture/firefly-python"
