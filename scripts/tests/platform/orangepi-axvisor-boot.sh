#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
work=$(mktemp -d /tmp/orangepi-axvisor-boot.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/tmp"
export TMPDIR="$work/tmp"
source "$repo_root/scripts/lib/rootfs-disk.sh"
info() { :; }
warn() { printf '%s\n' "$*" >&2; }

disk="$work/base.img"
truncate -s 80M "$disk"
sfdisk "$disk" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=8192, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="efi"
start=10240, size=81920, type=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7, name="boot"
start=92160, size=40960, type=0fc63daf-8483-4772-8e79-3d69d8477de4, name="rootfs"
EOF
root_partuuid=$(sfdisk --part-uuid "$disk" 3)
root_partuuid=${root_partuuid,,}
truncate -s 4M "$work/efi.img"
mkfs.vfat "$work/efi.img" >/dev/null
truncate -s 40M "$work/boot.img"
mkfs.vfat -F 32 "$work/boot.img" >/dev/null
printf original-linux-kernel >"$work/Image"
printf original-linux-initrd >"$work/uInitrd"
cat >"$work/boot.cmd" <<'BOOT'
setenv bootargs "root=UUID=54516f99-1a85-4579-a27c-c0f42a9c8650 rw rootwait rootfstype=ext4 console=ttyS2,1500000"
load ${devtype} ${devnum} ${ramdisk_addr_r} ${prefix}uInitrd
load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}Image
load ${devtype} ${devnum} ${fdt_addr_r} ${prefix}dtb/${fdtfile}
fdt addr ${fdt_addr_r}
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
BOOT
mkimage -C none -A arm -T script -d "$work/boot.cmd" "$work/boot.scr" >/dev/null
printf old-axvisor >"$work/AxVisor.bin"
mcopy -i "$work/boot.img" "$work/Image" "$work/uInitrd" "$work/boot.scr" "$work/AxVisor.bin" ::/
# A kernel-shaped file in the ESP must not make it the Linux boot partition.
mcopy -i "$work/efi.img" "$work/Image" ::/
mkdir -p "$work/root/etc" "$work/platform/axvisor/board-ballpick-robot/shared"
printf rootfs >"$work/root/etc/marker"
printf '# guest-config\n' >"$work/platform/axvisor/board-ballpick-robot/shared/linux.toml"
mkdir -p "$work/platform/axvisor/robot-single"
cat >"$work/platform/axvisor/robot-single/guest.toml" <<'GUEST'
[base]
id = 1
[kernel]
kernel_path = "/guest/axvisor/guests/starry-robot-single.bin"
cmdline = "root=/dev/mmcblk0p2 rw"
GUEST
printf '{}\n' >"$work/platform/axvisor/manifest.json"
truncate -s 20M "$work/root.img"
mke2fs -q -t ext4 -F -U 54516f99-1a85-4579-a27c-c0f42a9c8650 -d "$work/root" "$work/root.img"
dd if="$work/efi.img" of="$disk" bs=512 seek=2048 conv=notrunc status=none
dd if="$work/boot.img" of="$disk" bs=512 seek=10240 conv=notrunc status=none
dd if="$work/root.img" of="$disk" bs=512 seek=92160 conv=notrunc status=none
find "$work/platform" -exec touch -h -d @1700000000 {} +
original=$(sha256sum "$disk")
printf new-axvisor-image >"$work/AxVisor.bin"
output="$work/output.img"
rootfs_compose_disk_guest "$disk" "$work/platform" "$work/root.img" \
    aarch64 orangepi-jammy 1M 1M "$output" prebuilt "$work/AxVisor.bin"
[[ $(sha256sum "$disk") == "$original" ]]
rootfs_disk_extract_partition "$output" 2048 8192 "$work/output-efi.img"
cmp "$work/efi.img" "$work/output-efi.img"
rootfs_disk_extract_partition "$output" 10240 81920 "$work/output-boot.img"
fsck.vfat -n "$work/output-boot.img" >/dev/null
mcopy -i "$work/output-boot.img" ::/AxVisor.bin "$work/readback.bin"
cmp "$work/AxVisor.bin" "$work/readback.bin"
mcopy -i "$work/output-boot.img" ::/Image "$work/readback-Image"
cmp "$work/Image" "$work/readback-Image"
mcopy -i "$work/output-boot.img" ::/uInitrd "$work/readback-uInitrd"
cmp "$work/uInitrd" "$work/readback-uInitrd"
mcopy -i "$work/output-boot.img" ::/boot.scr "$work/readback-boot.scr"
dumpimage -T script -p 0 -o "$work/default-boot.cmd" "$work/readback-boot.scr" >/dev/null
grep -Fxq 'load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}AxVisor.bin' "$work/default-boot.cmd"
grep -Fxq 'booti ${kernel_addr_r} - ${fdt_addr_r}' "$work/default-boot.cmd"
grep -Fxq 'if part uuid ${devtype} ${devnum}:3 axvisor_root_partuuid; then' "$work/default-boot.cmd"
grep -Fxq 'setenv bootargs "root=PARTUUID=${axvisor_root_partuuid} rw rootwait rootfstype=ext4 console=ttyS2,1500000"' "$work/default-boot.cmd"
! grep -q 'root=UUID=' "$work/default-boot.cmd"
! grep -q 'uInitrd' "$work/default-boot.cmd"
grep -Fxq 'load ${devtype} ${devnum} ${fdt_addr_r} ${prefix}dtb/${fdtfile}' "$work/default-boot.cmd"
mcopy -i "$work/output-boot.img" ::/boot-linux.scr "$work/readback-boot-linux.scr"
dumpimage -T script -p 0 -o "$work/linux-boot.payload" "$work/readback-boot-linux.scr" >/dev/null
mcopy -i "$work/output-boot.img" ::/boot-linux.cmd "$work/readback-boot-linux.cmd"
grep -Fxq 'load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}Image' "$work/readback-boot-linux.cmd"
grep -Fxq 'load ${devtype} ${devnum} ${ramdisk_addr_r} ${prefix}uInitrd' "$work/readback-boot-linux.cmd"
grep -Fxq 'booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}' "$work/readback-boot-linux.cmd"
! grep -q 'root=UUID=' "$work/readback-boot-linux.cmd"
read -r root_partno start size _ < <(rootfs_disk_find_root_partition "$output")
final_root_partuuid=$(sfdisk --part-uuid "$output" "$root_partno")
[[ ${final_root_partuuid,,} == "$root_partuuid" ]]

# Execute the generated root-selection block with host shell equivalents of
# U-Boot's part/setenv builtins. Partition lookups read a real GPT; this checks
# generated control flow and late identity resolution, not U-Boot hardware.
python3 - "$repo_root" "$work/default-boot.cmd" "$work/root-setup.sh" \
    "$work/linux-boot.payload" "$work/linux-root-setup.sh" "$work/readback-boot-linux.cmd" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('boot', Path(sys.argv[1]) / 'scripts/lib/python/orangepi-boot.py')
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)
for payload, output in [(sys.argv[2], sys.argv[3]), (sys.argv[4], sys.argv[5])]:
    source = boot.script_source(Path(payload).read_bytes())
    Path(output).write_text(source.split('\nload ', 1)[0] + '\nprintf "%s\\n" "$bootargs"\n')
assert boot.script_source(Path(sys.argv[4]).read_bytes()) == Path(sys.argv[6]).read_text()
PY
cp --sparse=always "$output" "$work/runtime-disk.img"
runtime_root() {
    RUNTIME_DISK="$work/runtime-disk.img" bash -euc '
        devtype=mmc devnum=0
        part() {
            [[ $1 == uuid && $2 == mmc && ${3%:*} == 0 ]] || return 1
            local value
            value=$(sfdisk --part-uuid "$RUNTIME_DISK" "${3##*:}") || return 1
            [[ -n $value ]] || return 1
            printf -v "$4" %s "${value,,}"
        }
        setenv() { local key=$1; shift; printf -v "$key" %s "$*"; }
        source "$1"
    ' _ "${1:-$work/root-setup.sh}"
}
[[ $(runtime_root) == *"root=PARTUUID=$root_partuuid "* ]]
[[ $(runtime_root "$work/linux-root-setup.sh") == *"root=PARTUUID=$root_partuuid "* ]]
new_root_partuuid=12345678-1234-5678-9abc-123456789abc
sfdisk --part-uuid "$work/runtime-disk.img" "$root_partno" "$new_root_partuuid"
[[ $(runtime_root) == *"root=PARTUUID=$new_root_partuuid "* ]]
[[ $(runtime_root "$work/linux-root-setup.sh") == *"root=PARTUUID=$new_root_partuuid "* ]]
sfdisk --delete "$work/runtime-disk.img" "$root_partno" >/dev/null
for setup in "$work/root-setup.sh" "$work/linux-root-setup.sh"; do
    if runtime_root "$setup" >"$work/missing-root.log" 2>&1; then
        printf 'missing root partition unexpectedly continued\n' >&2
        exit 1
    fi
done
printf 'ok - both boot modes follow changed GPT identity and stop if the root partition is absent\n'
rootfs_disk_extract_partition "$output" "$start" "$size" "$work/output-root.img"
[[ $(debugfs -R 'cat /guest/axvisor/board-ballpick-robot/shared/linux.toml' \
    "$work/output-root.img" 2>/dev/null) == '# guest-config' ]]
debugfs -R 'cat /guest/axvisor/robot-single/guest.toml' "$work/output-root.img" 2>/dev/null >"$work/robot-single.toml"
grep -Fq 'root=PARTLABEL=rootfs rw' "$work/robot-single.toml"
grep -Fq 'root=/dev/mmcblk0p2 rw' "$work/platform/axvisor/robot-single/guest.toml"
robot_sum=$(sha256sum "$work/robot-single.toml")
debugfs -R 'cat /guest/axvisor/SHA256SUMS' "$work/output-root.img" 2>/dev/null | \
    grep -Fq "${robot_sum%% *}  ./robot-single/guest.toml"
[[ $(debugfs -R 'stat /guest/axvisor/AxVisor.bin' "$work/output-root.img" 2>&1) == *'File not found'* ]]
printf 'ok - default boot.scr loads AxVisor.bin without Linux initrd; Linux fallback retains Image/initrd, EFI, and shared configs\n'

# A boot filesystem without a kernel must fail before publishing any disk.
mcopy -i "$work/efi.img" "$work/boot.scr" ::/
mdel -i "$work/boot.img" ::/Image
dd if="$work/boot.img" of="$disk" bs=512 seek=10240 conv=notrunc status=none
printf previous-image >"$output"
if rootfs_compose_disk_guest "$disk" "$work/platform" "$work/root.img" \
    aarch64 orangepi-jammy 1M 1M "$output" prebuilt "$work/AxVisor.bin" \
    >"$work/missing-boot.log" 2>&1; then
    printf 'missing Linux boot partition unexpectedly succeeded\n' >&2
    exit 1
fi
[[ $(cat "$output") == previous-image ]]
grep -q 'no Linux FAT boot partition' "$work/missing-boot.log"
! grep -q 'unbound variable' "$work/missing-boot.log"
printf 'ok - missing Linux boot partition preserves previously published image\n'

# A full FAT filesystem must also preserve the previous publication.
printf previous-image >"$output"
mcopy -i "$work/boot.img" "$work/Image" ::/
dd if="$work/boot.img" of="$disk" bs=512 seek=10240 conv=notrunc status=none
truncate -s 48M "$work/oversize.bin"
if rootfs_compose_disk_guest "$disk" "$work/platform" "$work/root.img" \
    aarch64 orangepi-jammy 1M 1M "$output" prebuilt "$work/oversize.bin" \
    >"$work/full-boot.log" 2>&1; then
    printf 'full boot partition unexpectedly succeeded\n' >&2
    exit 1
fi
[[ $(cat "$output") == previous-image ]]
grep -qi 'disk full' "$work/full-boot.log"
[[ -z $(find "$TMPDIR" -maxdepth 1 -name 'rootfs-boot-*' -print -quit) ]]
printf 'ok - full Linux boot partition preserves previously published image\n'

# Do not publish an image if an unexpected script could leave Linux default.
printf 'echo unsupported-boot-layout\n' >"$work/unsupported.cmd"
mkimage -C none -A arm -T script -d "$work/unsupported.cmd" "$work/unsupported.scr" >/dev/null
mcopy -o -i "$work/boot.img" "$work/unsupported.scr" ::/boot.scr
dd if="$work/boot.img" of="$disk" bs=512 seek=10240 conv=notrunc status=none
if rootfs_compose_disk_guest "$disk" "$work/platform" "$work/root.img" \
    aarch64 orangepi-jammy 1M 1M "$output" prebuilt "$work/AxVisor.bin" \
    >"$work/unsupported-boot.log" 2>&1; then
    printf 'unsupported boot script unexpectedly succeeded\n' >&2
    exit 1
fi
[[ $(cat "$output") == previous-image ]]
grep -q 'unsupported' "$work/unsupported-boot.log"
printf 'ok - unsupported boot script cannot publish an image with the wrong default\n'
