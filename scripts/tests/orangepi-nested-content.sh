#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)

image=
guest_free_value=256M
outer_free_value=256M
skip_elf_check=0

usage() {
    printf 'Usage: %s --image <orangepi.img> [--guest-free-size <size>] [--outer-free-size <size>] [--skip-elf-check]\n' "$0"
    printf 'Environment: ROOTFS_GUEST_COUNT selects zero-based guest images (default 2, range 1-8).\n'
}

while (($#)); do
    case $1 in
    --image) (($# >= 2)) || { usage >&2; exit 2; }; image=$2; shift 2 ;;
    --guest-free-size) (($# >= 2)) || { usage >&2; exit 2; }; guest_free_value=$2; shift 2 ;;
    --outer-free-size) (($# >= 2)) || { usage >&2; exit 2; }; outer_free_value=$2; shift 2 ;;
    --skip-elf-check) skip_elf_check=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n $image && -f $image ]] || { usage >&2; exit 2; }

warn() { printf 'warning: %s\n' "$*" >&2; }
info() { :; }
die() { printf 'orangepi-content: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
source "$repo_root/scripts/lib/rootfs.sh"
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/rootfs-compose.sh"
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/rootfs-disk.sh"

work=$(mktemp -d /tmp/orangepi-nested-content.XXXXXX)
trap 'rm -rf "$work"' EXIT

image_has_path() {
    local filesystem=$1 path=$2 output
    output=$(debugfs -R "stat $path" "$filesystem" 2>&1) || return 1
    [[ $output != *'File not found'* && $output == *'Inode:'* ]]
}

dump_path() {
    local filesystem=$1 source=$2 destination=$3
    debugfs -R "dump $source $destination" "$filesystem" >/dev/null 2>&1
    [[ -f $destination ]]
}

validate_runtime_elf() {
    local filesystem=$1 path=$2 host_file binary_dir interpreter needed runpath entry candidate resolved
    local -a search_dirs=()
    resolved=$(rootfs_ext4_resolve_file "$filesystem" "$path") || die "ELF path is not a real file: $path"
    host_file="$work/$(basename -- "$path").elf"
    dump_path "$filesystem" "$resolved" "$host_file" || die "cannot extract ELF: $path"
    LC_ALL=C readelf -h "$host_file" | grep -Eq 'Machine:[[:space:]]+AArch64' ||
        die "not an AArch64 ELF: $path"
    interpreter=$(LC_ALL=C readelf -l "$host_file" |
        sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    if [[ -n $interpreter ]]; then
        rootfs_ext4_resolve_file "$filesystem" "$interpreter" >/dev/null ||
            die "missing ELF interpreter $interpreter for $path"
    fi
    binary_dir=${path%/*}
    runpath=$(LC_ALL=C readelf -d "$host_file" 2>/dev/null |
        sed -n 's/.*(RUNPATH).*\[\(.*\)\].*/\1/p; s/.*(RPATH).*\[\(.*\)\].*/\1/p' | head -1)
    if [[ -n $runpath ]]; then
        local IFS=:
        for entry in $runpath; do
            entry=${entry//'${ORIGIN}'/$binary_dir}
            entry=${entry//'$ORIGIN'/$binary_dir}
            [[ $entry == /* ]] || entry="$binary_dir/$entry"
            search_dirs+=("$entry")
        done
    fi
    search_dirs+=(/lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu /lib64 /usr/lib64 /lib /usr/lib)
    while IFS= read -r needed; do
        [[ -n $needed ]] || continue
        candidate=
        for entry in "${search_dirs[@]}"; do
            if candidate=$(rootfs_ext4_resolve_file "$filesystem" "$entry/$needed"); then
                break
            fi
        done
        [[ -n $candidate ]] || die "missing shared library $needed for $path"
    done < <(LC_ALL=C readelf -d "$host_file" 2>/dev/null |
        sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
}

read -r partno start size label < <(rootfs_disk_find_root_partition "$image") ||
    die 'cannot locate outer root partition'
outer="$work/outer.img"
rootfs_disk_extract_partition "$image" "$start" "$size" "$outer" ||
    die 'cannot extract outer root partition'
_rootfs_check_clean "$outer" || die 'outer root filesystem is not clean'

nested_base=rootfs-aarch64-orangepi-jammy.img
guest_count=$(_rootfs_guest_count) || die 'invalid ROOTFS_GUEST_COUNT'
nested=
declare -A guest_inodes=()
for ((guest_index = 0; guest_index < guest_count; guest_index++)); do
    guest_name=$(_rootfs_guest_image_name "$nested_base" "$guest_index") || die 'cannot name guest image'
    guest_path="/guest/$guest_name"
    guest_file="$work/$guest_name"
    image_has_path "$outer" "$guest_path" || die "missing nested image: $guest_path"
    dump_path "$outer" "$guest_path" "$guest_file" || die "cannot extract nested root filesystem: $guest_path"
    if [[ -z $nested ]]; then
        nested=$guest_file
    else
        cmp -s "$nested" "$guest_file" || die 'guest images have different initial contents'
    fi
    guest_inode=$(_rootfs_debugfs_stat "$outer" "$guest_path" required | awk '/^Inode:/ {print $2}')
    [[ -z ${guest_inodes[$guest_inode]+set} ]] || die 'guest images share an inode'
    guest_inodes[$guest_inode]=1
done
_rootfs_check_clean "$nested" || die 'nested root filesystem is not clean'

guest_free=$(rootfs_parse_size_bytes "$guest_free_value") || die 'invalid guest free size'
outer_free=$(rootfs_parse_size_bytes "$outer_free_value") || die 'invalid outer free size'
(( $(rootfs_ext4_free_bytes "$nested") >= guest_free )) || die 'nested rootfs reserve is too small'
(( $(rootfs_ext4_free_bytes "$outer") >= outer_free )) || die 'outer rootfs reserve is too small'

for test_path in \
    /guest-tests/cyclictest/cyclictest \
    /guest-tests/lmbench/lat_syscall \
    /guest-tests/iozone/iozone; do
    if [[ $test_path == /guest-tests/lmbench/lat_syscall ]]; then
        test_path=/guest-tests/lmbench/bin/Linux/lat_syscall
    fi
    image_has_path "$nested" "$test_path" || die "missing guest test executable: $test_path"
    ((skip_elf_check)) || validate_runtime_elf "$nested" "$test_path"
done

for ((guest_index = 0; guest_index < guest_count; guest_index++)); do
    guest_name=$(_rootfs_guest_image_name "$nested_base" "$guest_index") || die 'cannot name guest image'
    ! image_has_path "$nested" "/guest/$guest_name" || die 'nested rootfs recursively contains itself'
done

printf 'Orange Pi nested rootfs validation passed: %s\n' "$image"
