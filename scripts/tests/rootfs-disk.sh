#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/rootfs-disk-test.XXXXXX)
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

warn() { printf 'warning: %s\n' "$*" >&2; }
info() { :; }
die() { printf 'error: %s\n' "$*" >&2; return 1; }

# shellcheck source=/dev/null
source "$repo_root/scripts/lib/rootfs.sh"
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/rootfs-compose.sh"
if [[ -f $repo_root/scripts/lib/rootfs-disk.sh ]]; then
    # shellcheck source=/dev/null
    source "$repo_root/scripts/lib/rootfs-disk.sh"
fi

tests=0
fail() { printf 'not ok %s - %s\n' "$tests" "$*" >&2; exit 1; }
pass() { printf 'ok %s - %s\n' "$tests" "$*"; }
run_ok() {
    local message=$1
    shift
    tests=$((tests + 1))
    if ! "$@" >"$work/stdout" 2>"$work/stderr"; then
        sed -n '1,120p' "$work/stderr" >&2
        fail "$message"
    fi
    pass "$message"
}
run_fail() {
    local message=$1
    shift
    tests=$((tests + 1))
    if "$@" >"$work/stdout" 2>"$work/stderr"; then
        fail "$message (unexpected success)"
    fi
    pass "$message"
}
assert_eq() {
    [[ $1 == "$2" ]] || fail "$3 (expected '$1', got '$2')"
}

make_ext4() {
    local image=$1 size=$2 marker=$3 tree
    tree=$(mktemp -d "$work/ext4-tree.XXXXXX")
    mkdir -p "$tree/etc"
    printf '%s\n' "$marker" >"$tree/etc/rootfs-marker"
    truncate -s "$size" "$image"
    mkfs.ext4 -q -F -d "$tree" "$image"
    rm -rf "$tree"
}

write_partition() {
    local disk=$1 start=$2 partition=$3
    dd if="$partition" of="$disk" bs=512 seek="$start" conv=notrunc status=none
}

grow_ext4() {
    local image=$1 size=$2
    e2fsck -fy "$image" >/dev/null 2>&1
    truncate -s "$size" "$image"
    resize2fs "$image" >/dev/null 2>&1
    e2fsck -fy "$image" >/dev/null 2>&1
}

partition_field() {
    local disk=$1 partno=$2 field=$3
    sfdisk -J "$disk" | python3 -c '
import json
import sys

partno = int(sys.argv[1])
field = sys.argv[2]
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
print(parts[partno - 1].get(field, ""))
' "$partno" "$field"
}

normalize_tree_seconds() {
    find "$1" -depth -mindepth 1 -type l -exec touch -h -d @1700000000 {} +
    find "$1" -depth -mindepth 1 ! -type l -exec touch -d @1700000000 {} +
    touch -d @1700000000 "$1"
}

has_path() {
    local image=$1 path=$2 output
    output=$(debugfs -R "stat $path" "$image" 2>&1) || return 1
    [[ $output != *'File not found'* && $output == *'Inode:'* ]]
}

make_gpt_fixture() {
    local disk=$1 efi wrong root
    truncate -s 80M "$disk"
    sfdisk "$disk" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=4096, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="efi"
start=8192, size=81920, type=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7, name="larger-wrong-type"
start=92160, size=49152, type=0fc63daf-8483-4772-8e79-3d69d8477de4, name="rootfs"
EOF
    efi="$work/efi.img"
    wrong="$work/wrong.img"
    root="$work/root.img"
    truncate -s 2M "$efi"
    make_ext4 "$wrong" 40M wrong-type
    make_ext4 "$root" 24M gpt-root
    write_partition "$disk" 2048 "$efi"
    write_partition "$disk" 8192 "$wrong"
    write_partition "$disk" 92160 "$root"
}

make_dos_fixture() {
    local disk=$1 root
    truncate -s 32M "$disk"
    sfdisk "$disk" >/dev/null <<'EOF'
label: dos
unit: sectors

start=2048, size=32768, type=83
EOF
    root="$work/dos-root.img"
    make_ext4 "$root" 16M dos-root
    write_partition "$disk" 2048 "$root"
}

gpt_disk="$work/gpt.img"
make_gpt_fixture "$gpt_disk"
run_ok 'GPT discovery requires a Linux type and chooses the ext4 root' \
    rootfs_disk_find_root_partition "$gpt_disk"
assert_eq '3 92160 49152 gpt' "$(cat "$work/stdout")" 'GPT root partition metadata'

extracted="$work/extracted.img"
run_ok 'partition extraction publishes an ext4 image' \
    rootfs_disk_extract_partition "$gpt_disk" 92160 49152 "$extracted"
assert_eq gpt-root "$(debugfs -R 'cat /etc/rootfs-marker' "$extracted" 2>/dev/null)" \
    'extracted GPT root marker'

printf keep >"$work/existing.img"
run_fail 'partition extraction never overwrites an existing output' \
    rootfs_disk_extract_partition "$gpt_disk" 92160 49152 "$work/existing.img"
assert_eq keep "$(cat "$work/existing.img")" 'existing extraction target remains unchanged'

dos_disk="$work/dos.img"
make_dos_fixture "$dos_disk"
run_ok 'DOS discovery accepts Linux type 83' rootfs_disk_find_root_partition "$dos_disk"
assert_eq '1 2048 32768 dos' "$(cat "$work/stdout")" 'DOS root partition metadata'

blank_disk="$work/blank.img"
truncate -s 16M "$blank_disk"
run_fail 'a disk without a partition table is rejected' rootfs_disk_find_root_partition "$blank_disk"

non_ext_disk="$work/non-ext.img"
truncate -s 32M "$non_ext_disk"
sfdisk "$non_ext_disk" >/dev/null <<'EOF'
label: dos
unit: sectors

start=2048, size=32768, type=83
EOF
run_fail 'a Linux partition without ext4 is rejected' rootfs_disk_find_root_partition "$non_ext_disk"

ambiguous_disk="$work/ambiguous.img"
truncate -s 48M "$ambiguous_disk"
sfdisk "$ambiguous_disk" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=32768, type=0fc63daf-8483-4772-8e79-3d69d8477de4
start=36864, size=32768, type=0fc63daf-8483-4772-8e79-3d69d8477de4
EOF
make_ext4 "$work/ambiguous-a.img" 16M ambiguous-a
make_ext4 "$work/ambiguous-b.img" 16M ambiguous-b
write_partition "$ambiguous_disk" 2048 "$work/ambiguous-a.img"
write_partition "$ambiguous_disk" 36864 "$work/ambiguous-b.img"
run_fail 'equal largest ext4 candidates are rejected as ambiguous' \
    rootfs_disk_find_root_partition "$ambiguous_disk"

sparse_disk="$work/sparse-numbering.img"
truncate -s 48M "$sparse_disk"
printf '%s\n' 'label: gpt' 'unit: sectors' '' \
    "$sparse_disk"'1 : start=2048, size=16384, type=0fc63daf-8483-4772-8e79-3d69d8477de4' \
    "$sparse_disk"'3 : start=24576, size=32768, type=0fc63daf-8483-4772-8e79-3d69d8477de4' |
    sfdisk "$sparse_disk" >/dev/null
make_ext4 "$work/sparse-one.img" 8M sparse-one
make_ext4 "$work/sparse-three.img" 16M sparse-three
write_partition "$sparse_disk" 2048 "$work/sparse-one.img"
write_partition "$sparse_disk" 24576 "$work/sparse-three.img"
run_ok 'sparse GPT numbering reports the actual root partition number' \
    rootfs_disk_find_root_partition "$sparse_disk"
assert_eq '3 24576 32768 gpt' "$(cat "$work/stdout")" \
    'sparse GPT root partition metadata'

short_disk="$work/short.img"
cp "$gpt_disk" "$short_disk"
truncate -s 60M "$short_disk"
run_fail 'partition bounds beyond the disk are rejected' rootfs_disk_find_root_partition "$short_disk"

symlink_tree="$work/symlink-tree"
mkdir -p "$symlink_tree/lib"
printf library >"$symlink_tree/lib/libreal.so"
ln -s libreal.so "$symlink_tree/lib/librelative.so"
ln -s /lib/libreal.so "$symlink_tree/lib/libabsolute.so"
ln -s missing.so "$symlink_tree/lib/libdangling.so"
ln -s loop-b.so "$symlink_tree/lib/loop-a.so"
ln -s loop-a.so "$symlink_tree/lib/loop-b.so"
ln -s ../../outside "$symlink_tree/lib/libescape.so"
truncate -s 16M "$work/symlinks.img"
mkfs.ext4 -q -F -d "$symlink_tree" "$work/symlinks.img"
run_ok 'relative ext4 symlinks resolve to a real file' \
    rootfs_ext4_resolve_file "$work/symlinks.img" /lib/librelative.so
assert_eq /lib/libreal.so "$(cat "$work/stdout")" 'relative ext4 symlink result'
run_ok 'absolute ext4 symlinks resolve inside the image' \
    rootfs_ext4_resolve_file "$work/symlinks.img" /lib/libabsolute.so
assert_eq /lib/libreal.so "$(cat "$work/stdout")" 'absolute ext4 symlink result'
run_fail 'dangling ext4 symlinks are rejected' \
    rootfs_ext4_resolve_file "$work/symlinks.img" /lib/libdangling.so
run_fail 'ext4 symlink loops are rejected' \
    rootfs_ext4_resolve_file "$work/symlinks.img" /lib/loop-a.so
run_fail 'ext4 symlinks cannot escape the image root' \
    rootfs_ext4_resolve_file "$work/symlinks.img" /lib/libescape.so

growing_disk="$work/growing-gpt.img"
cp "$gpt_disk" "$growing_disk"
rootfs_disk_extract_partition "$growing_disk" 92160 49152 "$work/growing-root.img"
grow_ext4 "$work/growing-root.img" 40M
before_disk_size=$(stat -c %s "$growing_disk")
before_type=$(partition_field "$growing_disk" 3 type)
before_uuid=$(partition_field "$growing_disk" 3 uuid)
before_name=$(partition_field "$growing_disk" 3 name)
run_ok 'a last GPT partition grows atomically for a larger ext4' \
    rootfs_disk_replace_partition "$growing_disk" 3 92160 49152 "$work/growing-root.img"
run_ok 'grown GPT remains valid' sfdisk --verify "$growing_disk"
assert_eq 92160 "$(partition_field "$growing_disk" 3 start)" 'grown GPT start remains fixed'
assert_eq 81920 "$(partition_field "$growing_disk" 3 size)" 'grown GPT size follows ext4 length'
assert_eq "$before_type" "$(partition_field "$growing_disk" 3 type)" 'grown GPT type is preserved'
assert_eq "$before_uuid" "$(partition_field "$growing_disk" 3 uuid)" 'grown GPT UUID is preserved'
assert_eq "$before_name" "$(partition_field "$growing_disk" 3 name)" 'grown GPT name is preserved'
run_ok 'disk grows when the replacement crosses its old boundary' \
    test "$(stat -c %s "$growing_disk")" -gt "$before_disk_size"
rootfs_disk_extract_partition "$growing_disk" 92160 81920 "$work/reextracted-grown.img"
run_ok 're-extracted grown ext4 is clean' e2fsck -fn "$work/reextracted-grown.img"

nonlast_disk="$work/nonlast-gpt.img"
truncate -s 64M "$nonlast_disk"
sfdisk "$nonlast_disk" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=32768, type=0fc63daf-8483-4772-8e79-3d69d8477de4, name="rootfs"
start=40960, size=8192, type=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7, name="after-root"
EOF
make_ext4 "$work/nonlast-root.img" 16M nonlast-root
write_partition "$nonlast_disk" 2048 "$work/nonlast-root.img"
rootfs_disk_extract_partition "$nonlast_disk" 2048 32768 "$work/nonlast-same.img"
printf replacement >"$work/replacement-marker"
debugfs -w -R "write $work/replacement-marker /etc/replacement-marker" \
    "$work/nonlast-same.img" >/dev/null 2>&1
before_table=$(sfdisk -d "$nonlast_disk")
run_ok 'a fitting non-last partition can be replaced without growth' \
    rootfs_disk_replace_partition "$nonlast_disk" 1 2048 32768 "$work/nonlast-same.img"
assert_eq "$before_table" "$(sfdisk -d "$nonlast_disk")" \
    'fitting non-last replacement leaves the partition table unchanged'
rm -f "$work/reextracted-nonlast.img"
rootfs_disk_extract_partition "$nonlast_disk" 2048 32768 "$work/reextracted-nonlast.img"
assert_eq replacement \
    "$(debugfs -R 'cat /etc/replacement-marker' "$work/reextracted-nonlast.img" 2>/dev/null)" \
    'fitting non-last replacement writes the new ext4 payload'

cp "$work/nonlast-same.img" "$work/nonlast-grown.img"
grow_ext4 "$work/nonlast-grown.img" 20M
before_nonlast_sha=$(sha256sum "$nonlast_disk" | awk '{print $1}')
run_fail 'a non-last partition cannot grow' \
    rootfs_disk_replace_partition "$nonlast_disk" 1 2048 32768 "$work/nonlast-grown.img"
assert_eq "$before_nonlast_sha" "$(sha256sum "$nonlast_disk" | awk '{print $1}')" \
    'rejected non-last growth leaves the disk unchanged'

shrinking_dos="$work/shrinking-dos.img"
cp "$dos_disk" "$shrinking_dos"
rootfs_disk_extract_partition "$shrinking_dos" 2048 32768 "$work/shrunk-root.img"
rootfs_compact_ext4 "$work/shrunk-root.img" 1M
before_dos_size=$(stat -c %s "$shrinking_dos")
run_ok 'a smaller DOS ext4 replaces data without shrinking its partition' \
    rootfs_disk_replace_partition "$shrinking_dos" 1 2048 32768 "$work/shrunk-root.img"
assert_eq 32768 "$(partition_field "$shrinking_dos" 1 size)" \
    'smaller replacement preserves DOS partition size'
assert_eq "$before_dos_size" "$(stat -c %s "$shrinking_dos")" \
    'smaller replacement preserves DOS disk size'

growing_dos="$work/growing-dos.img"
cp "$dos_disk" "$growing_dos"
rootfs_disk_extract_partition "$growing_dos" 2048 32768 "$work/growing-dos-root.img"
grow_ext4 "$work/growing-dos-root.img" 20M
run_ok 'a last DOS type 83 partition can grow' \
    rootfs_disk_replace_partition "$growing_dos" 1 2048 32768 "$work/growing-dos-root.img"
assert_eq dos "$(partition_field "$growing_dos" 1 type | sed 's/^83$/dos/')" \
    'grown DOS table remains DOS'
assert_eq 40960 "$(partition_field "$growing_dos" 1 size)" \
    'grown DOS partition size follows ext4 length'

compose_base="$work/compose-base.img"
cp "$gpt_disk" "$compose_base"
compose_base_sha=$(sha256sum "$compose_base" | awk '{print $1}')
touch -d @1700000100 "$compose_base"
platform_stage="$work/platform-stage"
guest_overlay="$work/guest-overlay"
mkdir -p "$platform_stage/linux" "$platform_stage/platform" "$platform_stage/arceos" \
    "$guest_overlay/guest-tests/cyclictest" \
    "$guest_overlay/guest-tests/lmbench/bin/Linux" \
    "$guest_overlay/guest-tests/iozone"
printf kernel >"$platform_stage/linux/orangepi-5-plus"
printf outer >"$platform_stage/platform/outer-only"
printf arceos >"$platform_stage/arceos/orangepi-5-plus"
dd if=/dev/zero of="$platform_stage/platform/large-payload" bs=1M count=20 status=none
printf cyclic >"$guest_overlay/guest-tests/cyclictest/cyclictest"
printf lmbench >"$guest_overlay/guest-tests/lmbench/bin/Linux/lat_syscall"
printf iozone >"$guest_overlay/guest-tests/iozone/iozone"
normalize_tree_seconds "$platform_stage"
normalize_tree_seconds "$guest_overlay"
touch -d '2026-09-17 05:08:24.622733865 +0000' \
    "$platform_stage/arceos/orangepi-5-plus" "$platform_stage/arceos"
fractional_arceos_timestamp=$(stat -c '%x|%y' "$platform_stage/arceos/orangepi-5-plus")

composed="$work/composed.img"
run_ok 'a disk image composes a same-origin nested guest transactionally' \
    rootfs_compose_disk_guest "$compose_base" "$platform_stage" "$guest_overlay" \
        aarch64 orangepi-jammy 8M 8M "$composed"
assert_eq "$compose_base_sha" "$(sha256sum "$compose_base" | awk '{print $1}')" \
    'composition leaves the base disk content unchanged'
assert_eq 1700000100 "$(stat -c %Y "$compose_base")" \
    'composition leaves the base disk timestamp unchanged'
assert_eq "$fractional_arceos_timestamp" \
    "$(stat -c '%x|%y' "$platform_stage/arceos/orangepi-5-plus")" \
    'composition leaves fractional platform source timestamps unchanged'

read -r composed_part composed_start composed_size _ < <(rootfs_disk_find_root_partition "$composed")
rootfs_disk_extract_partition "$composed" "$composed_start" "$composed_size" "$work/composed-outer.img"
has_path "$work/composed-outer.img" /guest/linux/orangepi-5-plus || \
    fail 'outer image lacks staged platform kernel'
has_path "$work/composed-outer.img" /guest/rootfs-aarch64-orangepi-jammy.img || \
    fail 'outer image lacks nested Orange Pi rootfs'
debugfs -R "dump /guest/rootfs-aarch64-orangepi-jammy.img $work/nested.img" \
    "$work/composed-outer.img" >/dev/null 2>&1
debugfs -R "dump /guest/rootfs-aarch64-orangepi-jammy-2.img $work/nested-2.img" \
    "$work/composed-outer.img" >/dev/null 2>&1
run_ok 'disk composition embeds two identical guests' cmp "$work/nested.img" "$work/nested-2.img"
run_ok 'nested Orange Pi rootfs is clean' e2fsck -fn "$work/nested.img"
assert_eq gpt-root "$(debugfs -R 'cat /etc/rootfs-marker' "$work/nested.img" 2>/dev/null)" \
    'nested rootfs comes from the unmodified Orange Pi root partition'
has_path "$work/nested.img" /guest-tests/cyclictest/cyclictest || fail 'nested rootfs lacks cyclictest'
has_path "$work/nested.img" /guest-tests/lmbench/bin/Linux/lat_syscall || fail 'nested rootfs lacks lmbench'
has_path "$work/nested.img" /guest-tests/iozone/iozone || fail 'nested rootfs lacks iozone'
! has_path "$work/nested.img" /guest/platform/outer-only || \
    fail 'nested rootfs contains outer-only platform content'
! has_path "$work/nested.img" /guest/rootfs-aarch64-orangepi-jammy.img || \
    fail 'nested rootfs recursively contains itself'
run_ok 'nested rootfs keeps its configured reserve' \
    test "$(rootfs_ext4_free_bytes "$work/nested.img")" -ge $((8 * 1024 * 1024))
run_ok 'outer rootfs keeps its configured reserve' \
    test "$(rootfs_ext4_free_bytes "$work/composed-outer.img")" -ge $((8 * 1024 * 1024))
run_ok 'the Orange Pi content validator accepts the composed fixture' \
    bash "$repo_root/scripts/tests/orangepi-nested-content.sh" \
        --image "$composed" --guest-free-size 8M --outer-free-size 8M --skip-elf-check

prebuilt_composed="$work/prebuilt-composed.img"
run_ok 'a disk image embeds an independently published guest rootfs' \
    rootfs_compose_disk_guest "$compose_base" "$platform_stage" "$work/nested.img" \
        aarch64 orangepi-jammy 8M 8M "$prebuilt_composed" prebuilt
read -r _ prebuilt_start prebuilt_size _ < <(rootfs_disk_find_root_partition "$prebuilt_composed")
rootfs_disk_extract_partition "$prebuilt_composed" "$prebuilt_start" "$prebuilt_size" \
    "$work/prebuilt-outer.img"
debugfs -R "dump /guest/rootfs-aarch64-orangepi-jammy.img $work/prebuilt-nested.img" \
    "$work/prebuilt-outer.img" >/dev/null 2>&1
assert_eq gpt-root "$(debugfs -R 'cat /etc/rootfs-marker' "$work/prebuilt-nested.img" 2>/dev/null)" \
    'prebuilt nested rootfs content is preserved'
has_path "$work/prebuilt-nested.img" /guest-tests/iozone/iozone || \
    fail 'prebuilt nested rootfs lost its benchmark payload'

roomy_disk="$work/roomy.img"
truncate -s 96M "$roomy_disk"
sfdisk "$roomy_disk" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=163840, type=0fc63daf-8483-4772-8e79-3d69d8477de4, name="roomy-rootfs"
EOF
make_ext4 "$work/roomy-root.img" 80M roomy-root
write_partition "$roomy_disk" 2048 "$work/roomy-root.img"
roomy_disk_size=$(stat -c %s "$roomy_disk")
roomy_part_size=$(partition_field "$roomy_disk" 1 size)
roomy_platform="$work/roomy-platform"
mkdir -p "$roomy_platform/linux"
printf kernel >"$roomy_platform/linux/kernel"
normalize_tree_seconds "$roomy_platform"
run_ok 'composition does not grow an already roomy outer partition' \
    rootfs_compose_disk_guest "$roomy_disk" "$roomy_platform" "$guest_overlay" \
        aarch64 orangepi-jammy 4M 4M "$work/roomy-output.img"
assert_eq "$roomy_disk_size" "$(stat -c %s "$work/roomy-output.img")" \
    'roomy composition preserves disk length'
assert_eq "$roomy_part_size" "$(partition_field "$work/roomy-output.img" 1 size)" \
    'roomy composition preserves root partition length'

printf previous-output >"$work/preserved-output.img"
protected_platform="$work/protected-platform"
mkdir -p "$protected_platform"
printf collision >"$protected_platform/rootfs-aarch64-orangepi-jammy.img"
normalize_tree_seconds "$protected_platform"
run_fail 'a protected nested-image collision aborts composition' \
    rootfs_compose_disk_guest "$compose_base" "$protected_platform" "$guest_overlay" \
        aarch64 orangepi-jammy 8M 8M "$work/preserved-output.img"
assert_eq previous-output "$(cat "$work/preserved-output.img")" \
    'failed composition preserves an existing output'

fault_bin="$work/fault-bin"
mkdir "$fault_bin"
real_mv=$(command -v mv)
cat >"$fault_bin/mv" <<EOF
#!/usr/bin/env bash
destination=\${@: -1}
if [[ -n \${FAIL_MV_DESTINATION:-} && \$destination == "\$FAIL_MV_DESTINATION" ]]; then
    exit 70
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$fault_bin/mv"
printf old-published-image >"$work/mv-failure-output.img"
compose_with_failed_publish() {
    PATH="$fault_bin:$PATH" FAIL_MV_DESTINATION="$work/mv-failure-output.img" \
        rootfs_compose_disk_guest "$compose_base" "$platform_stage" "$guest_overlay" \
            aarch64 orangepi-jammy 8M 8M "$work/mv-failure-output.img"
}
run_fail 'a final publication failure preserves the old disk image' compose_with_failed_publish
assert_eq old-published-image "$(cat "$work/mv-failure-output.img")" \
    'failed final publication leaves old bytes intact'

tests=$((tests + 1))
if find "$work" -type f -name '*.lock' -print -quit | grep -q .; then
    fail 'disk operations left lock files behind'
fi
pass 'disk operations clean lock files after success and failure'

printf '1..%s\n' "$tests"
