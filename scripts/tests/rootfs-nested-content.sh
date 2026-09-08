#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck source=../lib/rootfs-compose.sh
source "$repo_root/scripts/lib/rootfs-compose.sh"
# shellcheck source=../rootfs-tests/lib/common.sh
source "$repo_root/scripts/rootfs-tests/lib/common.sh"

image_dir="$repo_root/IMAGES/rootfs"
selected_arch=''
selected_rootfs=''
guest_tests='cyclictest,lmbench,iozone'
guest_free_size=256M
outer_free_size=256M
declare -a outer_only_paths=()
tmp_dir=''

usage() {
    cat <<EOF
Usage: $0 [options]

Verify composed outer ext4 rootfs images and their nested guest images.

  --image-dir <dir>           Image directory (default: IMAGES/rootfs)
  --arch <arch>               Select aarch64, riscv64, x86_64, or loongarch64
  --rootfs <type>             Select busybox, alpine, or debian
  --guest-tests <list>        Expected nested plugins (default: cyclictest,lmbench,iozone)
  --guest-free-size <size>    Minimum nested free bytes (default: 256M)
  --outer-free-size <size>    Minimum outer free bytes (default: 256M)
  --outer-only-path <path>    Require path in outer and forbid it in nested (repeatable)
  -h, --help                  Show this help
EOF
}

die() { printf 'rootfs-nested-content: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z $tmp_dir ]] || rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

need_value() { (($# >= 2)) || { usage >&2; exit 2; }; }
while (($#)); do
    case $1 in
    --image-dir) need_value "$@"; image_dir=$2; shift 2 ;;
    --arch) need_value "$@"; selected_arch=$2; shift 2 ;;
    --rootfs) need_value "$@"; selected_rootfs=$2; shift 2 ;;
    --guest-tests) need_value "$@"; guest_tests=$2; shift 2 ;;
    --guest-free-size) need_value "$@"; guest_free_size=$2; shift 2 ;;
    --outer-free-size) need_value "$@"; outer_free_size=$2; shift 2 ;;
    --outer-only-path) need_value "$@"; outer_only_paths+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
    esac
done

case $selected_arch in ''|aarch64|riscv64|x86_64|loongarch64) ;; *) die "unsupported architecture: $selected_arch" ;; esac
case $selected_rootfs in ''|busybox|alpine|debian) ;; *) die "unsupported rootfs: $selected_rootfs" ;; esac
guest_free_bytes=$(rootfs_parse_size_bytes "$guest_free_size") || die "invalid guest free size: $guest_free_size"
outer_free_bytes=$(rootfs_parse_size_bytes "$outer_free_size") || die "invalid outer free size: $outer_free_size"
[[ $guest_tests == none || $guest_tests == all || ($guest_tests != ,* && $guest_tests != *, && $guest_tests != *,,*) ]] ||
    die "invalid guest test selection: $guest_tests"
for path in "${outer_only_paths[@]}"; do
    [[ $path =~ ^/[A-Za-z0-9._/+:-]+$ ]] || die "invalid outer-only path: $path"
done
[[ -d $image_dir ]] || die "image directory does not exist: $image_dir"
image_dir=$(CDPATH= cd -- "$image_dir" && pwd -P) || die "cannot resolve image directory: $image_dir"
for tool in debugfs dumpe2fs e2fsck readelf awk grep; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

debugfs_stat() {
    local image=$1 path=$2 output
    output=$(debugfs -R "stat \"$path\"" "$image" 2>/dev/null) || return 1
    grep -q '^Inode:' <<<"$output"
}

require_path() {
    debugfs_stat "$1" "$2" || die "missing required image path: $2 in $1"
}

forbid_path() {
    ! debugfs_stat "$1" "$2" || die "unexpected image path: $2 in $1"
}

forbid_nested_rootfs_images() {
    local image=$1 listing
    debugfs_stat "$image" /guest || return 0
    listing=$(debugfs -R 'ls -p "/guest"' "$image" 2>/dev/null) ||
        die "cannot inspect nested /guest directory: $image"
    ! grep -Eq '/rootfs-[^/]*\.img/' <<<"$listing" ||
        die "nested image contains a recursive rootfs under /guest: $image"
}

dump_required() {
    local image=$1 path=$2 destination=$3
    rm -f -- "$destination"
    require_path "$image" "$path"
    debugfs -R "dump -p \"$path\" \"$destination\"" "$image" >/dev/null 2>&1 ||
        die "cannot dump image path: $path in $image"
    [[ -f $destination ]] || die "image path is not a regular file: $path in $image"
}

check_executable_path() {
    dump_required "$1" "$2" "$3"
    [[ -x $3 ]] || die "image path is not executable: $2"
}

check_static_elf() {
    local image=$1 path=$2 arch=$3 destination=$4 header
    dump_required "$image" "$path" "$destination"
    [[ -x $destination ]] || die "image ELF is not executable: $path"
    header=$(LC_ALL=C readelf -h -- "$destination") || die "not an ELF file: $path"
    grep -q 'Class:[[:space:]]*ELF64' <<<"$header" || die "ELF is not ELF64: $path"
    rootfs_test_validate_elf "$arch" "$destination" || die "unexpected ELF machine: $path"
    ! LC_ALL=C readelf -l -- "$destination" | grep -q INTERP || die "ELF has an interpreter: $path"
    ! LC_ALL=C readelf -d -- "$destination" | grep -q '(NEEDED)' || die "ELF has shared dependencies: $path"
}

check_plugin() {
    local image=$1 arch=$2 plugin=$3 plugin_tmp=$4 script
    case $plugin in
    cyclictest)
        check_static_elf "$image" /guest-tests/cyclictest/cyclictest "$arch" "$plugin_tmp/cyclictest"
        ;;
    lmbench)
        check_static_elf "$image" /guest-tests/lmbench/bin/Linux/bw_mem "$arch" "$plugin_tmp/lmbench-bw_mem"
        check_static_elf "$image" /guest-tests/lmbench/bin/Linux/lat_syscall "$arch" "$plugin_tmp/lmbench-lat_syscall"
        check_executable_path "$image" /guest-tests/lmbench/bin/Linux/lmbench "$plugin_tmp/lmbench-launcher"
        for script in lmbench config-run results config os gnu-os info info-template version; do
            check_executable_path "$image" "/guest-tests/lmbench/scripts/$script" "$plugin_tmp/lmbench-script-$script"
        done
        ;;
    iozone)
        check_static_elf "$image" /guest-tests/iozone/iozone "$arch" "$plugin_tmp/iozone"
        ;;
    *) require_path "$image" "/guest-tests/$plugin" ;;
    esac
}

check_initramfs() {
    local archive=$1 arch=$2 rootfs=$3 unpack
    [[ $rootfs == busybox && -f $archive ]] || return 0
    for tool in fakeroot cpio gzip; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done
    unpack=$(mktemp -d "$tmp_dir/initramfs.XXXXXX")
    (cd "$unpack" && fakeroot sh -c \
        'gzip -dc -- "$1" | cpio -idm --no-absolute-filenames --no-preserve-owner 2>/dev/null' _ "$archive") ||
        die "cannot unpack BusyBox initramfs: $archive"
    [[ ! -e $unpack/guest-tests ]] || die "BusyBox initramfs contains /guest-tests: $archive"
    if [[ -d $unpack/guest ]] && find "$unpack/guest" -maxdepth 1 -name 'rootfs-*.img' -print -quit | grep -q .; then
        die "BusyBox initramfs contains nested rootfs: $archive"
    fi
}

tmp_dir=$(mktemp -d /tmp/rootfs-nested-content.XXXXXX)
declare -a images=()
shopt -s nullglob
for image in "$image_dir"/rootfs-*-*.img; do
    name=${image##*/}
    if [[ $name =~ ^rootfs-(aarch64|riscv64|x86_64|loongarch64)-(busybox|alpine|debian)\.img$ ]]; then
        arch=${BASH_REMATCH[1]}
        rootfs=${BASH_REMATCH[2]}
        [[ -z $selected_arch || $arch == "$selected_arch" ]] || continue
        [[ -z $selected_rootfs || $rootfs == "$selected_rootfs" ]] || continue
        images+=("$image")
    fi
done
shopt -u nullglob
if ((${#images[@]} == 0)); then
    [[ -z $selected_arch || -z $selected_rootfs ]] ||
        die "missing selected rootfs image: $image_dir/rootfs-$selected_arch-$selected_rootfs.img"
    die "no matching rootfs images in: $image_dir"
fi

for outer in "${images[@]}"; do
    name=${outer##*/}
    [[ $name =~ ^rootfs-(aarch64|riscv64|x86_64|loongarch64)-(busybox|alpine|debian)\.img$ ]]
    arch=${BASH_REMATCH[1]}
    rootfs=${BASH_REMATCH[2]}
    nested_path="/guest/rootfs-$arch-$rootfs.img"
    nested="$tmp_dir/nested-$arch-$rootfs.img"
    e2fsck -fn "$outer" >/dev/null || die "outer ext4 check failed: $outer"
    dump_required "$outer" "$nested_path" "$nested"
    e2fsck -fn "$nested" >/dev/null || die "nested ext4 check failed: $nested_path"

    outer_free=$(rootfs_ext4_free_bytes "$outer") || die "cannot read outer free space: $outer"
    nested_free=$(rootfs_ext4_free_bytes "$nested") || die "cannot read nested free space: $nested_path"
    ((outer_free >= outer_free_bytes)) || die "outer free space is below $outer_free_size: $outer"
    ((nested_free >= guest_free_bytes)) || die "nested free space is below $guest_free_size: $nested_path"

    forbid_path "$nested" /opt/ltp
    forbid_nested_rootfs_images "$nested"
    forbid_path "$nested" /run-all.sh
    forbid_path "$nested" /guest-tests/run-all.sh
    for path in "${outer_only_paths[@]}"; do
        require_path "$outer" "$path"
        forbid_path "$nested" "$path"
    done

    tests=$guest_tests
    if [[ $tests == all ]]; then
        tests=$("$repo_root/scripts/rootfs-tests/build.sh" list --arch "$arch" --rootfs "$rootfs" --scope guest) ||
            die "cannot list guest plugins for $arch/$rootfs"
        tests=${tests//$'\n'/,}
        tests=${tests%,}
    fi
    if [[ $tests != none ]]; then
        IFS=, read -r -a plugins <<<"$tests"
        for plugin in "${plugins[@]}"; do
            check_plugin "$nested" "$arch" "$plugin" "$tmp_dir"
        done
    fi

    if [[ $rootfs == alpine ]]; then
        "$script_dir/alpine-ltp-content.sh" --image-dir "$image_dir" --arch "$arch" ||
            die "Alpine outer LTP validation failed: $outer"
    fi
    check_initramfs "$image_dir/initramfs-$arch-busybox.cpio.gz" "$arch" "$rootfs"
    printf 'verified nested rootfs content: %s/%s\n' "$arch" "$rootfs"
done
