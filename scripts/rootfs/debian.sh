#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs-compose.sh"

DEBIAN_ARCH=""
DEBIAN_OUT_DIR=""
DEBIAN_GUEST_DIR=""
DEBIAN_OUTPUT=""
DEBIAN_OUTER_TESTS=""
DEBIAN_GUEST_TESTS=""
DEBIAN_GUEST_FREE_SIZE=""
DEBIAN_OUTER_FREE_SIZE=""
DEBIAN_IMG_SIZE="${DEBIAN_IMG_SIZE:-1G}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_PASSWORD="${DEBIAN_PASSWORD:-root}"
DEBIAN_DEFAULT_PACKAGES=(
    binutils
    gcc
    musl-dev
    libusb-1.0-0-dev
    git
    vim
)

DEBIAN_DOCKER_IMAGE=""
DEBIAN_DOCKER_PLATFORM=""
DEBIAN_DPKG_ARCH=""
DEBIAN_TARGET=""
DEBIAN_ROOTFS_IMG=""
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_ARCHES=("aarch64" "riscv64" "x86_64")
# DEBIAN_ARCHES=("aarch64" "riscv64" "x86_64" "loongarch64")

debian_usage() {
    printf 'Build Debian-based rootfs image\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rootfs/debian.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64                       Build Debian rootfs for aarch64\n'
    printf '  riscv64                       Build Debian rootfs for riscv64\n'
    printf '  x86_64                        Build Debian rootfs for x86_64\n'
    # printf '  loongarch64                   Build Debian rootfs for loongarch64\n'
    printf '  all                           Build Debian rootfs for all supported architectures\n'
    printf '  clean                         Clean generated images for all supported architectures\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --out_dir <dir>               Output directory (default image: IMAGES/rootfs/rootfs-<arch>-debian.img)\n'
    printf '  --output <path>               Output image path for single-arch build\n'
    printf '  --guest <dir>                 Guest directory to copy into rootfs /guest\n'
    printf '  --outer-tests <list>          Tests installed in the outer image (default: none)\n'
    printf '  --guest-tests <list>          Tests installed in the nested guest image (default from rootfs-tests)\n'
    printf '  --guest-free-size <size>      Free space reserved in nested guest image (default: 256M)\n'
    printf '  --outer-free-size <size>      Free space reserved in outer image (default: 256M)\n'
    printf '  --img-size <size>             Output image size (default: 1G)\n'
    printf '  --debian <suite>              Debian suite (default: trixie)\n'
    printf '  --password <password>         Root password (default: root)\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  DEBIAN_IMG_SIZE               Output image size\n'
    printf '  DEBIAN_SUITE                  Debian suite\n'
    printf '  DEBIAN_PASSWORD               Root password\n'
    printf '  DEBIAN_MIRROR                 Debian mirror URL\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * Uses Docker + debootstrap to generate an ext4 rootfs image.\n'
    printf '  * Docker --mount output parents containing commas are rejected; spaces, colons, and quotes are supported.\n'
    printf '  * Guest/overlay inputs must use safe path names and whole-second timestamps; xattrs, extended ACLs, and special files are rejected.\n'
    printf '  * Defaults to Debian trixie because riscv64 is not reliably available in bookworm here.\n'
    printf '  * The all command currently targets: aarch64, riscv64, x86_64.\n'
    # printf '  * Debian 13 (trixie) does not currently ship loong64 packages in the main archive.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rootfs/debian.sh aarch64\n'
    printf '  scripts/rootfs/debian.sh riscv64 --debian trixie --img-size 3G\n'
    printf '  scripts/rootfs/debian.sh x86_64 --out_dir /tmp/rootfs\n'
    # printf '  scripts/rootfs/debian.sh loongarch64 --guest /path/to/guest/files\n'
    printf '  scripts/rootfs/debian.sh all --out_dir IMAGES/rootfs\n'
}

debian_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out_dir)
                (($# >= 2)) || die "missing value for --out_dir"
                DEBIAN_OUT_DIR="$2"
                shift 2
                ;;
            --output|-o)
                (($# >= 2)) || die "missing value for --output"
                DEBIAN_OUTPUT="$2"
                shift 2
                ;;
            --guest)
                (($# >= 2)) || die "missing value for --guest"
                DEBIAN_GUEST_DIR="$2"
                shift 2
                ;;
            --img-size|-s)
                (($# >= 2)) || die "missing value for --img-size"
                DEBIAN_IMG_SIZE="$2"
                shift 2
                ;;
            --debian|--suite|-d)
                (($# >= 2)) || die "missing value for --debian"
                DEBIAN_SUITE="$2"
                shift 2
                ;;
            --password|-p)
                (($# >= 2)) || die "missing value for --password"
                DEBIAN_PASSWORD="$2"
                shift 2
                ;;
            --outer-tests)
                (($# >= 2)) || die "missing value for --outer-tests"
                DEBIAN_OUTER_TESTS=$2
                shift 2
                ;;
            --guest-tests)
                (($# >= 2)) || die "missing value for --guest-tests"
                DEBIAN_GUEST_TESTS=$2
                shift 2
                ;;
            --guest-free-size)
                (($# >= 2)) || die "missing value for --guest-free-size"
                DEBIAN_GUEST_FREE_SIZE=$2
                shift 2
                ;;
            --outer-free-size)
                (($# >= 2)) || die "missing value for --outer-free-size"
                DEBIAN_OUTER_FREE_SIZE=$2
                shift 2
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

debian_check_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found. Please install Docker first."
    docker info >/dev/null 2>&1 || die "Docker daemon is not running."
}

debian_validate_suite_support() {
    if [[ "${DEBIAN_ARCH}" == "loongarch64" && "${DEBIAN_SUITE}" == "trixie" ]]; then
        die "Debian ${DEBIAN_SUITE} does not provide loong64 packages in the main archive. Please use sid/unstable or a debian-ports-based workflow for loongarch64."
    fi
}

debian_init_config() {
    local output_parent output_name
    case "${DEBIAN_ARCH}" in
        aarch64)
            DEBIAN_TARGET="aarch64-unknown-none-softfloat"
            DEBIAN_DOCKER_PLATFORM="linux/arm64"
            DEBIAN_DPKG_ARCH="arm64"
            ;;
        riscv64)
            DEBIAN_TARGET="riscv64gc-unknown-none-elf"
            DEBIAN_DOCKER_PLATFORM="linux/riscv64"
            DEBIAN_DPKG_ARCH="riscv64"
            ;;
        x86_64)
            DEBIAN_TARGET="x86_64-unknown-none"
            DEBIAN_DOCKER_PLATFORM="linux/amd64"
            DEBIAN_DPKG_ARCH="amd64"
            ;;
        loongarch64)
            DEBIAN_TARGET="loongarch64-unknown-none"
            DEBIAN_DOCKER_PLATFORM="linux/loong64"
            DEBIAN_DPKG_ARCH="loong64"
            ;;
        *)
            die "Unsupported Debian architecture: ${DEBIAN_ARCH}"
            ;;
    esac

    DEBIAN_DOCKER_IMAGE="debian:${DEBIAN_SUITE}"

    if [[ -n "${DEBIAN_GUEST_DIR}" ]]; then
        DEBIAN_GUEST_DIR="$(cd "${DEBIAN_GUEST_DIR}" 2>/dev/null && pwd -P)" || {
            die "Guest directory ${DEBIAN_GUEST_DIR} does not exist or is not accessible"
        }
    fi

    if [[ -n "${DEBIAN_OUTPUT}" ]]; then
        output_parent=$(dirname -- "$DEBIAN_OUTPUT")
        output_name=$(basename -- "$DEBIAN_OUTPUT")
    else
        output_parent="${DEBIAN_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
        output_name="rootfs-${DEBIAN_ARCH}-debian.img"
    fi
    mkdir -p -- "$output_parent" "${BUILD_DIR}/debian/${DEBIAN_ARCH}"
    output_parent=$(cd -- "$output_parent" && pwd -P)
    [[ $output_parent != *,* ]] || die "Debian output parent cannot contain a comma: $output_parent"
    DEBIAN_ROOTFS_IMG="$output_parent/$output_name"
}

debian_output_mount_arg() {
    printf 'type=bind,src=%s,dst=/output\n' "$(dirname -- "$DEBIAN_ROOTFS_IMG")"
}

debian_pack_rootfs_volume() {
    local volume_name=$1 debian_rootfs_tmp=$2 image_name
    image_name=$(basename -- "$debian_rootfs_tmp")
    docker run --rm --privileged \
        --platform "${DEBIAN_DOCKER_PLATFORM}" \
        -v "${volume_name}:/rootfs:ro" \
        --mount "$(debian_output_mount_arg)" \
        "${DEBIAN_DOCKER_IMAGE}" \
        bash -lc '
            set -euo pipefail
            apt-get update
            apt-get install -y e2fsprogs
            cd /output
            image_name=$1
            image_size=$2
            rm -f -- "$image_name"
            dd if=/dev/zero of="$image_name" bs=1 count=0 seek="$image_size" 2>/dev/null
            mkfs.ext4 -O ^orphan_file,^metadata_csum_seed -F -L starry-rootfs "$image_name"
            mkdir -p /mnt/rootfs
            mount -o loop "$image_name" /mnt/rootfs
            cp -a /rootfs/. /mnt/rootfs/
            sync
            umount /mnt/rootfs
            rmdir /mnt/rootfs
        ' bash "$image_name" "$DEBIAN_IMG_SIZE"
}

debian_build_rootfs() {
    local volume_name="starry-debian-rootfs-${DEBIAN_ARCH}-$$"

    info "Building Debian ${DEBIAN_SUITE} rootfs for ${DEBIAN_ARCH} (${DEBIAN_DPKG_ARCH})"
    info "Docker image: ${DEBIAN_DOCKER_IMAGE} (${DEBIAN_DOCKER_PLATFORM})"
    info "Output image: ${DEBIAN_ROOTFS_IMG}"

    docker volume create "${volume_name}" >/dev/null

    cleanup_volume() {
        docker volume rm "${volume_name}" >/dev/null 2>&1 || true
        rm -rf -- "${composition_dir:-}"
    }
    trap cleanup_volume EXIT

    info "Configuring Debian rootfs contents via debootstrap..."
    docker run --rm \
        --platform "${DEBIAN_DOCKER_PLATFORM}" \
        -v "${volume_name}:/rootfs" \
        "${DEBIAN_DOCKER_IMAGE}" \
        bash -lc "
            set -euo pipefail

            export DEBIAN_FRONTEND=noninteractive

            apt-get update
            apt-get install -y debootstrap e2fsprogs busybox-static bash

            debootstrap \
                --arch='${DEBIAN_DPKG_ARCH}' \
                --variant=minbase \
                --no-merged-usr \
                '${DEBIAN_SUITE}' \
                /rootfs \
                '${DEBIAN_MIRROR}'

            ROOTFS=/rootfs

            printf '%s\n' starry > \"\$ROOTFS/etc/hostname\"
            cat > \"\$ROOTFS/etc/hosts\" <<'EOF_HOSTS'
127.0.0.1 localhost starry
EOF_HOSTS

            cat > \"\$ROOTFS/etc/fstab\" <<'EOF_FSTAB'
/dev/vda  /  ext4  defaults,noatime  0  1
EOF_FSTAB

            chroot \"\$ROOTFS\" /usr/sbin/chpasswd <<'EOF_PASSWD'
root:${DEBIAN_PASSWORD}
EOF_PASSWD

            chroot \"\$ROOTFS\" apt-get update
            chroot \"\$ROOTFS\" apt-get install -y --reinstall libc6
            chroot \"\$ROOTFS\" apt-get install -y busybox-static bash ${DEBIAN_DEFAULT_PACKAGES[*]}

            if [ ! -e \"\$ROOTFS/sbin/init\" ]; then
                ln -sf /bin/busybox \"\$ROOTFS/sbin/init\"
            fi

            cat > \"\$ROOTFS/etc/inittab\" <<'EOF_INITTAB'
# /etc/inittab - busybox init for Starry OS
::sysinit:/etc/init.d/rcS
::respawn:-/bin/sh
::shutdown:/bin/umount -a -r
EOF_INITTAB

            mkdir -p \"\$ROOTFS/etc/init.d\"
            cat > \"\$ROOTFS/etc/init.d/rcS\" <<'EOF_RCS'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null
hostname starry
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF_RCS
            chmod +x \"\$ROOTFS/etc/init.d/rcS\"

            mkdir -p \"\$ROOTFS/etc/apt/apt.conf.d\"
            printf '%s\n' 'APT::Sandbox::User \"root\";' > \"\$ROOTFS/etc/apt/apt.conf.d/99no-sandbox\"
            printf '%s\n' 'APT::Cache-Start \"67108864\";' > \"\$ROOTFS/etc/apt/apt.conf.d/99cache-start\"

            mkdir -p \"\$ROOTFS/root\"
            cat > \"\$ROOTFS/root/init.sh\" <<'EOF_INIT_SH'
#!/bin/sh
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo ''
echo 'Welcome to Starry OS (Debian GNU/Linux)'
echo ''
echo 'Use apt to install packages.'
echo ''
cd ~
sh --login
EOF_INIT_SH
            chmod +x \"\$ROOTFS/root/init.sh\"

            cat > \"\$ROOTFS/root/.profile\" <<'EOF_PROFILE'
export PS1='starry:~# '
EOF_PROFILE

            mkdir -p \"\$ROOTFS/etc/network\"
            cat > \"\$ROOTFS/etc/network/interfaces\" <<'EOF_NET'
auto eth0
iface eth0 inet dhcp
EOF_NET

            cat > \"\$ROOTFS/etc/resolv.conf\" <<'EOF_RESOLV'
# SLIRP default DNS server
# See https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP)
nameserver 10.0.2.3
EOF_RESOLV

            chroot \"\$ROOTFS\" apt-get clean
            rm -rf \"\$ROOTFS/var/lib/apt/lists/\"*
            rm -rf \"\$ROOTFS/var/cache/apt/archives/\"*.deb
        "

    info "Packing ext4 image ${DEBIAN_ROOTFS_IMG} (${DEBIAN_IMG_SIZE})..."
    local debian_rootfs_tmp="${DEBIAN_ROOTFS_IMG}.base.tmp.$$"
    cleanup_rootfs_tmp() {
        rm -f "${debian_rootfs_tmp}" "${debian_rootfs_tmp}.lock"
        cleanup_volume
    }
    trap cleanup_rootfs_tmp EXIT
    rm -f "${debian_rootfs_tmp}"
    debian_pack_rootfs_volume "$volume_name" "$debian_rootfs_tmp"
    rootfs_compose_test_images "${debian_rootfs_tmp}" "${DEBIAN_OUTER_TEST_OVERLAY}" \
        "${DEBIAN_GUEST_TEST_OVERLAY}" "${DEBIAN_OUTER_GUEST_DIR}" "${DEBIAN_ARCH}" debian \
        "${DEBIAN_GUEST_FREE_SIZE}" "${DEBIAN_OUTER_FREE_SIZE}" "${DEBIAN_ROOTFS_IMG}"
    rm -f -- "${debian_rootfs_tmp}" "${debian_rootfs_tmp}.lock"

    trap - EXIT
    cleanup_volume

    success "Debian rootfs created: ${DEBIAN_ROOTFS_IMG}"
}

debian() (
    debian_init_config
    rootfs_builder_load_test_options debian DEBIAN_OUTER_TESTS DEBIAN_GUEST_TESTS \
        DEBIAN_GUEST_FREE_SIZE DEBIAN_OUTER_FREE_SIZE
    rootfs_builder_validate_reserves "$DEBIAN_GUEST_FREE_SIZE" "$DEBIAN_OUTER_FREE_SIZE"
    local composition_dir
    composition_dir=$(mktemp -d)
    trap 'rm -rf -- "$composition_dir"' EXIT
    DEBIAN_OUTER_GUEST_DIR="$composition_dir/outer-guest"
    if [[ -n $DEBIAN_GUEST_DIR ]]; then
        DEBIAN_OUTER_GUEST_DIR=$DEBIAN_GUEST_DIR
    else
        mkdir -p -- "$DEBIAN_OUTER_GUEST_DIR"
    fi
    rootfs_validate_payload_tree "$DEBIAN_OUTER_GUEST_DIR" || return 1
    rootfs_builder_prepare_test_overlays "$DEBIAN_ARCH" debian "$DEBIAN_OUTER_TESTS" \
        "$DEBIAN_GUEST_TESTS" "$composition_dir" DEBIAN_OUTER_TEST_OVERLAY DEBIAN_GUEST_TEST_OVERLAY || return 1
    _rootfs_validate_protected_outer_path "$DEBIAN_OUTER_GUEST_DIR" "$DEBIAN_OUTER_TEST_OVERLAY" \
        "rootfs-${DEBIAN_ARCH}-debian.img"
    debian_validate_suite_support
    debian_check_docker
    debian_build_rootfs
    rm -rf -- "$composition_dir"
    trap - EXIT
)

debian_clean_outputs() {
    local output_dir="${DEBIAN_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"

    if [[ -n "${DEBIAN_OUTPUT}" ]]; then
        rm -f "${DEBIAN_OUTPUT}" "${DEBIAN_OUTPUT}".base.tmp.*
        success "Debian rootfs output cleaned: ${DEBIAN_OUTPUT}"
        return 0
    fi

    rm -f \
        "${output_dir}/rootfs-aarch64-debian.img" \
        "${output_dir}/rootfs-riscv64-debian.img" \
        "${output_dir}/rootfs-x86_64-debian.img"
    rm -f -- "${output_dir}"/rootfs-*-debian.img.base.tmp.*
        # "${output_dir}/rootfs-loongarch64-debian.img"
    success "Debian rootfs outputs cleaned in ${output_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true

    case "${cmd}" in
        ""|-h|--help|help)
            debian_usage
            exit 0
            ;;
        aarch64|riscv64|x86_64)
        # aarch64|riscv64|x86_64|loongarch64)
            debian_parse_args "$@"
            DEBIAN_ARCH="${cmd}"
            debian
            ;;
        all)
            debian_parse_args "$@"
            if [[ -n "${DEBIAN_OUTPUT}" ]]; then
                die "--output can only be used for a single architecture build"
            fi

            for arch in "${DEBIAN_ARCHES[@]}"; do
                DEBIAN_ARCH="${arch}"
                debian
            done
            ;;
        clean)
            debian_parse_args "$@"
            debian_clean_outputs
            ;;
        *)
            die "Unknown command: ${cmd}"
            ;;
    esac
fi
