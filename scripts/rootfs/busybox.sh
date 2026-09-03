#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs-compose.sh"

# Default values
BUSYBOX_REPO_URL="${BUSYBOX_REPO_URL:-https://github.com/mirror/busybox.git}"
BUSYBOX_REF="${BUSYBOX_REF:-371fe9f71d445d18be28c82a2a6d82115c8af19d}"
BUSYBOX_SRC_DIR="${BUSYBOX_SRC_DIR:-${BUILD_DIR}/busybox}"
BUSYBOX_PATCH_DIR="${BUSYBOX_PATCH_DIR:-${ROOT_DIR}/patches/busybox}"
MKFS_ARCHES=("aarch64" "loongarch64" "riscv64" "x86_64")

# Global variables for parsed arguments
MKFS_ARCH=""
MKFS_OUT_DIR=""
MKFS_GUEST_DIR=""
MKFS_ARGS=""
MKFS_OUTER_TESTS=""
MKFS_GUEST_TESTS=""
MKFS_GUEST_FREE_SIZE=""
MKFS_OUTER_FREE_SIZE=""

mkfs_usage() {
    printf 'Generate a filesystem image containing BusyBox and basic device nodes\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rootfs/busybox.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64                       Build minimal filesystem for aarch64\n'
    printf '  loongarch64                   Build minimal filesystem for loongarch64\n'
    printf '  riscv64                       Build minimal filesystem for riscv64\n'
    printf '  x86_64                        Build minimal filesystem for x86_64\n'
    printf '  all                           Build minimal filesystem for all supported architectures\n'
    printf '  clean                         Clean generated images for all supported architectures\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --out_dir <dir>               Output directory (default images: IMAGES/rootfs/{initramfs-<arch>-busybox.cpio.gz,rootfs-<arch>-busybox.img})\n'
    printf '  --guest <dir>                 Guest directory to copy into rootfs /guest\n'
    printf '  --outer-tests <list>          Tests installed in the outer image (default: none)\n'
    printf '  --guest-tests <list>          Tests installed in the nested guest image (default from rootfs-tests)\n'
    printf '  --guest-free-size <size>      Free space reserved in nested guest image (default: 256M)\n'
    printf '  --outer-free-size <size>      Free space reserved in outer image (default: 256M)\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  BUSYBOX_REPO_URL              BusyBox repository URL\n'
    printf '  BUSYBOX_REF                   BusyBox git commit/ref\n'
    printf '  BUSYBOX_SRC_DIR               BusyBox source directory\n'
    printf '  BUSYBOX_PATCH_DIR             BusyBox patch directory\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * If BusyBox is dynamically linked, required shared libraries are copied automatically.\n'
    printf '  * Guest/overlay inputs must use safe path names and whole-second timestamps; xattrs, extended ACLs, and special files are rejected.\n'
    printf '  * The init script drops to an interactive shell after mounting basic pseudo filesystems.\n'
    printf '  * The all command currently targets: aarch64, loongarch64, riscv64, x86_64.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rootfs/busybox.sh aarch64\n'
    printf '  scripts/rootfs/busybox.sh all\n'
    printf '  scripts/rootfs/busybox.sh riscv64 --out_dir /tmp/output\n'
    printf '  scripts/rootfs/busybox.sh aarch64 --guest /path/to/guest/files\n'
}

mkfs_clean_outputs() {
    local output_dir="${MKFS_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    rm -f \
        "${output_dir}/initramfs-aarch64-busybox.cpio.gz" \
        "${output_dir}/initramfs-loongarch64-busybox.cpio.gz" \
        "${output_dir}/initramfs-riscv64-busybox.cpio.gz" \
        "${output_dir}/initramfs-x86_64-busybox.cpio.gz" \
        "${output_dir}/rootfs-aarch64-busybox.img" \
        "${output_dir}/rootfs-loongarch64-busybox.img" \
        "${output_dir}/rootfs-riscv64-busybox.img" \
        "${output_dir}/rootfs-x86_64-busybox.img"
    rm -f -- \
        "${output_dir}"/initramfs-*-busybox.cpio.gz.tmp.* \
        "${output_dir}"/initramfs-*-busybox.cpio.gz.publish.* \
        "${output_dir}"/rootfs-*-busybox.img.base.tmp.* \
        "${output_dir}"/rootfs-*-busybox.img.publish.* \
        "${output_dir}"/{initramfs-*,rootfs-*}-busybox.*.old.*
    success "BusyBox rootfs outputs cleaned in ${output_dir}"
}

mkfs_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --out_dir)
                (($# >= 2)) || die "missing value for --out_dir"
                MKFS_OUT_DIR="$2"
                shift 2
                ;;
            --guest)
                (($# >= 2)) || die "missing value for --guest"
                MKFS_GUEST_DIR="$2"
                shift 2
                ;;
            --outer-tests)
                (($# >= 2)) || die "missing value for --outer-tests"
                MKFS_OUTER_TESTS=$2
                shift 2
                ;;
            --guest-tests)
                (($# >= 2)) || die "missing value for --guest-tests"
                MKFS_GUEST_TESTS=$2
                shift 2
                ;;
            --guest-free-size)
                (($# >= 2)) || die "missing value for --guest-free-size"
                MKFS_GUEST_FREE_SIZE=$2
                shift 2
                ;;
            --outer-free-size)
                (($# >= 2)) || die "missing value for --outer-free-size"
                MKFS_OUTER_FREE_SIZE=$2
                shift 2
                ;;
            *)
                MKFS_ARGS="$MKFS_ARGS $1"
                shift
                ;;
        esac
    done
}

mkfs_build_busybox() {
    local cross=""
    if [[ "$MKFS_ARCH" == "x86_64" ]]; then
        cross=""
    else
        cross="${MKFS_ARCH}-linux-gnu-"
    fi
    pushd "${BUSYBOX_BUILD_SRC_DIR:-$BUSYBOX_SRC_DIR}" >/dev/null
    info "Cleaning: make distclean"
    make distclean

    info "Configuring: make defconfig"
    make defconfig

    info "Building: make -j$(nproc) CROSS_COMPILE=$cross"
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
    # BusyBox defconfig may enable x86 SHA-NI acceleration, which breaks
    # non-x86 cross builds because the matching assembly implementation is not used.
    sed -i 's/^CONFIG_SHA1_HWACCEL=y$/# CONFIG_SHA1_HWACCEL is not set/' .config
    make -j$(nproc) CROSS_COMPILE="$cross"
    popd >/dev/null
}

mkfs_pair_checkpoint() { :; }

mkfs_publish_pair() (
    local init_candidate=$1 init_final=$2 image_candidate=$3 image_final=$4
    local lock_path="${init_final}.pair.lock" init_backup="${init_final}.old.$$" image_backup="${image_final}.old.$$"
    local init_old=0 image_old=0 init_new=0 image_new=0 committed=0 lock_fd status=0 pending_signal=0
    exec {lock_fd}>"$lock_path" || return 1
    flock -x "$lock_fd" || return 1
    # Signal handlers only record intent throughout the critical section. This
    # prevents delivery between a filesystem operation and its state update.
    trap 'pending_signal=130' INT
    trap 'pending_signal=143' TERM
    pair_critical_mv() {
        local command_status
        trap '' INT TERM
        mv "$@"
        command_status=$?
        trap 'pending_signal=130' INT
        trap 'pending_signal=143' TERM
        return "$command_status"
    }
    pair_critical_rm() {
        local command_status
        trap '' INT TERM
        rm "$@"
        command_status=$?
        trap 'pending_signal=130' INT
        trap 'pending_signal=143' TERM
        return "$command_status"
    }

    if [[ -e $init_final ]]; then
        init_old=1
        mkfs_pair_checkpoint
        pair_critical_mv -T -- "$init_final" "$init_backup" || status=$?
        mkfs_pair_checkpoint
    fi
    if ((status == 0)) && [[ -e $image_final ]]; then
        image_old=1
        mkfs_pair_checkpoint
        pair_critical_mv -T -- "$image_final" "$image_backup" || status=$?
        mkfs_pair_checkpoint
    fi
    if ((status == 0)); then
        init_new=1
        mkfs_pair_checkpoint
        pair_critical_mv -T -- "$init_candidate" "$init_final" || status=$?
        mkfs_pair_checkpoint
    fi
    if ((status == 0)); then
        image_new=1
        mkfs_pair_checkpoint
        pair_critical_mv -T -- "$image_candidate" "$image_final" || status=$?
        if ((status == 0)); then committed=1; fi
        mkfs_pair_checkpoint
    fi

    if ((status != 0 && committed == 0)); then
        ((image_new == 0)) || pair_critical_rm -f -- "$image_final"
        ((init_new == 0)) || pair_critical_rm -f -- "$init_final"
        if ((image_old)) && [[ -e $image_backup ]]; then
            pair_critical_mv -T -- "$image_backup" "$image_final" || status=$?
        fi
        if ((init_old)) && [[ -e $init_backup ]]; then
            pair_critical_mv -T -- "$init_backup" "$init_final" || status=$?
        fi
    else
        if ((init_old)); then rm -f -- "$init_backup" || status=$?; mkfs_pair_checkpoint; fi
        if ((image_old)); then rm -f -- "$image_backup" || status=$?; mkfs_pair_checkpoint; fi
    fi
    init_old=0 image_old=0
    mkfs_pair_checkpoint
    init_new=0 image_new=0
    mkfs_pair_checkpoint
    rm -f -- "$init_candidate" "$image_candidate" "$init_backup" "$image_backup"
    flock -u "$lock_fd" || status=$?
    exec {lock_fd}>&-
    trap - INT TERM
    ((pending_signal == 0)) || return "$pending_signal"
    return "$status"
)

mkfs_add_ext4_devices() {
    local image=$1 commands spec device major minor expected output
    commands=$(mktemp)
    trap 'rm -f -- "$commands"' RETURN
    printf '%s\n' 'cd /dev' \
        'mknod console c 5 1' 'mknod null c 1 3' 'mknod zero c 1 5' \
        'mknod tty c 5 0' 'mknod ttyS0 c 4 64' >"$commands"
    LC_ALL=C debugfs -w -f "$commands" "$image" >/dev/null 2>&1 || return 1
    for spec in 'console 5 1' 'null 1 3' 'zero 1 5' 'tty 5 0' 'ttyS0 4 64'; do
        read -r device major minor <<<"$spec"
        LC_ALL=C debugfs -w -R "set_inode_field /dev/$device mode 020600" "$image" >/dev/null 2>&1 || return 1
        LC_ALL=C debugfs -w -R "set_inode_field /dev/$device uid 0" "$image" >/dev/null 2>&1 || return 1
        LC_ALL=C debugfs -w -R "set_inode_field /dev/$device gid 0" "$image" >/dev/null 2>&1 || return 1
        output=$(LC_ALL=C debugfs -R "stat /dev/$device" "$image" 2>&1) || return 1
        expected=$(printf '%02x:%02x' "$major" "$minor")
        grep -q '^Inode: .*Type: character special .*Mode:  *0600' <<<"$output" || return 1
        grep -Eq '^User: +0 +Group: +0 ' <<<"$output" || return 1
        grep -Fqi "(hex $expected)" <<<"$output" || return 1
    done
    rm -f -- "$commands"
    trap - RETURN
}

mkfs_prepare_busybox_source() {
    local lock_fd prepared="$composition_dir/busybox-source"
    exec {lock_fd}>"${BUSYBOX_SRC_DIR}.lock"
    flock -x "$lock_fd"
    info "Cloning busybox source repository $BUSYBOX_REPO_URL -> $BUSYBOX_SRC_DIR"
    clone_repository "$BUSYBOX_REPO_URL" "$BUSYBOX_SRC_DIR" || return 1
    info "Checking out busybox ref ${BUSYBOX_REF}"
    checkout_ref "$BUSYBOX_SRC_DIR" "$BUSYBOX_REF" || return 1
    if [[ -d "$BUSYBOX_PATCH_DIR" ]]; then
        info "Applying patches..."
        apply_patches "$BUSYBOX_PATCH_DIR" "$BUSYBOX_SRC_DIR" || return 1
    fi
    rm -rf -- "$prepared"
    cp -a --reflink=auto -- "$BUSYBOX_SRC_DIR" "$prepared" || return 1
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    BUSYBOX_BUILD_SRC_DIR=$prepared
}

mkfs_create_init() {
    printf '%s\n' \
        '#!/bin/sh' \
        'export PATH=/bin:/sbin:/usr/bin:/usr/sbin' \
        '' \
        'if [ -x /bin/busybox ]; then' \
        '    /bin/busybox --install -s >/dev/null 2>&1' \
        'fi' \
        '' \
        'TTY_DEV=/dev/console' \
        '[ -c /dev/ttyAMA0 ] && TTY_DEV=/dev/ttyAMA0' \
        '[ -c /dev/ttyS0 ] && TTY_DEV=/dev/ttyS0' \
        '' \
        'if [ ! -w "$TTY_DEV" ]; then' \
        '    echo "[ERROR] TTY_DEV ($TTY_DEV) is not writable. Falling back to /dev/console."' \
        '    TTY_DEV=/dev/console' \
        'fi' \
        '' \
        '/bin/busybox mkdir -p /proc /sys /dev /dev/pts /etc/init.d' \
        '/bin/busybox mount -t proc proc /proc >/dev/null 2>&1' \
        '/bin/busybox mount -t sysfs sysfs /sys >/dev/null 2>&1' \
        '/bin/busybox mount -t devtmpfs devtmpfs /dev >/dev/null 2>&1 || true' \
        '/bin/busybox mount -t devpts devpts /dev/pts >/dev/null 2>&1 || true' \
        '' \
        'echo "test pass!" > "$TTY_DEV" 2>/dev/null || echo "test pass!"' \
        'if command -v cttyhack >/dev/null 2>&1; then' \
        '    exec /bin/busybox cttyhack /bin/sh -i' \
        'elif command -v setsid >/dev/null 2>&1; then' \
        '    exec /bin/busybox setsid /bin/sh -i' \
        'else' \
        '    exec /bin/sh -i' \
        'fi' \
        > init
    chmod +x init
    # Create /etc/init.d/rcS to avoid busybox init errors
    mkdir -p etc/init.d
    echo '#!/bin/sh' > etc/init.d/rcS
    echo 'echo rcS running' >> etc/init.d/rcS
    chmod +x etc/init.d/rcS
}

mkfs_pack_fs() {
    # 0. Prepare working directory
    OUTPUT_DIR="${MKFS_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    mkdir -p "$OUTPUT_DIR"
    local abs_out="$OUTPUT_DIR/initramfs-${MKFS_ARCH}-busybox.cpio.gz"
    local abs_tmp="${abs_out}.publish.$$"
    local img_out="$OUTPUT_DIR/rootfs-${MKFS_ARCH}-busybox.img"
    local img_tmp="${img_out}.base.tmp.$$"
    local img_publish="${img_out}.publish.$$"
    local old_pwd
    
    # Convert guest directory to absolute path before changing directory
    if [[ -n "$MKFS_GUEST_DIR" ]]; then
        MKFS_GUEST_DIR="$(cd "$MKFS_GUEST_DIR" 2>/dev/null && pwd -P)" || {
            warn "Guest directory $MKFS_GUEST_DIR does not exist or is not accessible"
            MKFS_GUEST_DIR=""
        }
    fi
    
    TMP_DIR=$(mktemp -d)
    old_pwd="$(pwd)"
    MKFS_CLEANUP_TMP_DIR="$TMP_DIR"
    MKFS_CLEANUP_INITRAMFS_TMP="$abs_tmp"
    MKFS_CLEANUP_ROOTFS_TMP="$img_tmp"
    cleanup() {
        rm -rf "${MKFS_CLEANUP_TMP_DIR:-}" \
               "${MKFS_CLEANUP_INITRAMFS_TMP:-}" \
               "${MKFS_CLEANUP_ROOTFS_TMP:-}" \
               "${img_publish:-}" \
               "${composition_dir:-}"
        [[ -z ${MKFS_CLEANUP_ROOTFS_TMP:-} ]] || rm -f -- "${MKFS_CLEANUP_ROOTFS_TMP}.lock"
        [[ -z ${img_publish:-} ]] || rm -f -- "${img_publish}.lock"
    }
    trap cleanup EXIT
    cd "$TMP_DIR"
    echo "Creating minimal ramfs in $TMP_DIR"

    # 1. Create necessary directory structure
    mkdir -p bin sbin usr/bin usr/sbin dev dev/pts etc proc sys
    # 1.5 Copy guest directory if specified
    if [[ -n "$MKFS_GUEST_DIR" ]]; then
        if [[ -d "$MKFS_GUEST_DIR" ]]; then
            info "Copying guest directory: $MKFS_GUEST_DIR -> guest/"
            # Use rsync or cp with proper flags to ensure directory is copied
            if command -v rsync >/dev/null 2>&1; then
                rsync -a "$MKFS_GUEST_DIR/" guest/ 2>/dev/null || true
            else
                # Fallback to cp with recursive and archive flags
                cp -a "$MKFS_GUEST_DIR"/. guest/ 2>/dev/null || true
            fi
            # Verify guest directory was created
            if [[ -d "guest" ]]; then
                info "Guest directory copied successfully, contents:"
                ls -la guest/ || true
            else
                warn "Failed to create guest directory"
            fi
        else
            warn "Guest directory $MKFS_GUEST_DIR does not exist, skipping..."
        fi
    fi
    # 2. Install busybox and prepare content before the single fakeroot archive session.
    cp "${BUSYBOX_BUILD_SRC_DIR:-$BUSYBOX_SRC_DIR}/busybox" bin/
    if command -v ldd >/dev/null 2>&1; then
        ldd_output="$(ldd "${BUSYBOX_BUILD_SRC_DIR:-$BUSYBOX_SRC_DIR}/busybox" 2>&1 || true)"
        if ! printf '%s' "$ldd_output" | grep -q "not a dynamic executable"; then
            echo "BusyBox is dynamically linked; copying dependent libraries..."
            printf '%s' "$ldd_output" | awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }' | sort -u | while IFS= read -r lib; do
                [ -f "$lib" ] || continue
                rel_dir="${lib%/*}"
                mkdir -p ".${rel_dir}"
                cp -u "$lib" ".${lib}" 2>/dev/null || cp "$lib" ".${lib}" || true
            done
        fi
    fi
    [[ -e bin/sh ]] || ln -s busybox bin/sh
    # 4. Create init script
    mkfs_create_init
    [[ -e bin/init ]] || ln -s ../init bin/init

    # 5. Pack ramfs
    echo "Packing ramfs -> $abs_out"
    chmod 755 . || true
    fakeroot bash -c '
        set -e
        mknod -m 0600 dev/console c 5 1
        mknod -m 0600 dev/null c 1 3
        mknod -m 0600 dev/zero c 1 5
        mknod -m 0600 dev/tty c 5 0
        mknod -m 0600 dev/ttyS0 c 4 64
        find . -print0 | sort -z | cpio --null -H newc -o 2>/dev/null | gzip -9 >"$1"
    ' bash "$abs_tmp"

    # --guest belongs in the legacy initramfs and the outer ext4 only. Remove
    # the staged copy and fakeroot placeholder nodes before creating the clean
    # common base; debugfs recreates devices with native ext4 inode metadata.
    rm -rf -- guest
    rm -f -- dev/console dev/null dev/zero dev/tty dev/ttyS0

    # 6. Pack ext4 rootfs.img
    local size_mb=32
    if [[ "${MKFS_ARCH}" == "loongarch64" ]]; then
        size_mb=96
    fi
    echo "Packing ext4 rootfs (debugfs write) -> $img_out"
    dd if=/dev/zero of="$img_tmp" bs=1M count=$size_mb status=none
    mkfs.ext4 -q -F "$img_tmp"
    if ! command -v debugfs >/dev/null 2>&1; then
        echo "Error: debugfs not found. Please install: sudo apt install e2fsprogs" >&2
        cd "$old_pwd"
        return 1
    fi
    find . -type d | while read -r d; do
        debugfs -w -R "mkdir ${d#.}" "$img_tmp" >/dev/null 2>&1
    done
    # Write regular files
    find . -type f | while read -r f; do
        debugfs -w -R "write $f ${f#.}" "$img_tmp" >/dev/null 2>&1
    done
    # Write symlinks
    find . -type l | while read -r lnk; do
        target=$(readlink "$lnk")
        debugfs -w -R "symlink ${lnk#.} $target" "$img_tmp" >/dev/null 2>&1
    done
    mkfs_add_ext4_devices "$img_tmp"
    rootfs_compose_test_images "$img_tmp" "$MKFS_OUTER_TEST_OVERLAY" \
        "$MKFS_GUEST_TEST_OVERLAY" "$MKFS_OUTER_GUEST_DIR" "$MKFS_ARCH" busybox \
        "$MKFS_GUEST_FREE_SIZE" "$MKFS_OUTER_FREE_SIZE" "$img_publish" || return 1
    # Pair publication is failure-safe for cooperating readers holding this
    # persistent lock; two path renames cannot be atomic to lock-free readers.
    mkfs_publish_pair "$abs_tmp" "$abs_out" "$img_publish" "$img_out" || return 1
    rm -f -- "$img_tmp" "${img_tmp}.lock"
    echo "Minimal ramfs created: $abs_out"
    du -h "$abs_out" | awk '{print "Size: "$1}'
    echo "rootfs.img created: $img_out"
    du -h "$img_out" | awk '{print "Size: "$1}'
    cd "$old_pwd"
    trap - EXIT
    cleanup
}

mkfs() (
    local composition_dir output_dir
    output_dir="${MKFS_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    rootfs_builder_load_test_options busybox MKFS_OUTER_TESTS MKFS_GUEST_TESTS \
        MKFS_GUEST_FREE_SIZE MKFS_OUTER_FREE_SIZE
    rootfs_builder_validate_reserves "$MKFS_GUEST_FREE_SIZE" "$MKFS_OUTER_FREE_SIZE"
    composition_dir=$(mktemp -d)
    trap 'rm -rf -- "$composition_dir"' EXIT
    MKFS_OUTER_GUEST_DIR="$composition_dir/outer-guest"
    if [[ -n $MKFS_GUEST_DIR && -d $MKFS_GUEST_DIR ]]; then
        MKFS_OUTER_GUEST_DIR=$(cd -- "$MKFS_GUEST_DIR" && pwd -P)
        MKFS_GUEST_DIR=$MKFS_OUTER_GUEST_DIR
    else
        [[ -z $MKFS_GUEST_DIR ]] || die "Guest directory $MKFS_GUEST_DIR does not exist or is not accessible"
        MKFS_GUEST_DIR=""
        mkdir -p -- "$MKFS_OUTER_GUEST_DIR"
    fi
    rootfs_validate_payload_tree "$MKFS_OUTER_GUEST_DIR" || return 1
    rootfs_builder_prepare_test_overlays "$MKFS_ARCH" busybox "$MKFS_OUTER_TESTS" \
        "$MKFS_GUEST_TESTS" "$composition_dir" MKFS_OUTER_TEST_OVERLAY MKFS_GUEST_TEST_OVERLAY || return 1
    _rootfs_validate_protected_outer_path "$MKFS_OUTER_GUEST_DIR" "$MKFS_OUTER_TEST_OVERLAY" \
        "rootfs-${MKFS_ARCH}-busybox.img"

    mkfs_prepare_busybox_source || return 1

    info "Starting to build busybox..."
    mkfs_build_busybox

    info "Packing filesystem..."
    mkfs_pack_fs
)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            mkfs_usage
            exit 0
            ;;
        aarch64|loongarch64|riscv64|x86_64)
            mkfs_parse_args "$@"
            MKFS_ARCH="$cmd"
            mkfs
            ;;
        all)
            mkfs_parse_args "$@"
            for arch in "${MKFS_ARCHES[@]}"; do
                MKFS_ARCH="${arch}"
                mkfs
            done
            ;;
        clean)
            mkfs_parse_args "$@"
            mkfs_clean_outputs
            ;;
        *)
            die "Unknown command: $cmd"
            ;;
    esac
fi
