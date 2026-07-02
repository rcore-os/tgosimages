#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ALPINE_SCRIPT_DIR="${SCRIPT_DIR}"
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

# Default values
ALPINE_ARCH=""
ALPINE_OUT_DIR=""
ALPINE_GUEST_DIR=""
ALPINE_IMG_SIZE="${ALPINE_IMG_SIZE:-2G}"
ALPINE_BASE="${ALPINE_BASE:-https://mirrors.tuna.tsinghua.edu.cn/alpine}"
ALPINE_REL="${ALPINE_REL:-v3.23}"
ALPINE_DOCKER_DNS="${ALPINE_DOCKER_DNS:-223.5.5.5,114.114.114.114}"
ALPINE_DOCKER_IMAGE_PREFIX="${ALPINE_DOCKER_IMAGE_PREFIX:-tgos/alpine}"
ALPINE_APK_DOCKER_ARCH="${ALPINE_APK_DOCKER_ARCH:-x86_64}"
ALPINE_APK_DOCKER_IMAGE="${ALPINE_APK_DOCKER_IMAGE:-}"
ALPINE_LTP_URL="${ALPINE_LTP_URL:-https://github.com/linux-test-project/ltp/releases/download/20260529/ltp-full-20260529.tar.xz}"
ALPINE_LTP_PREFIX="${ALPINE_LTP_PREFIX:-/opt/ltp}"
ALPINE_LTP_CFLAGS="${ALPINE_LTP_CFLAGS:-}"
ALPINE_LTP_LDFLAGS="${ALPINE_LTP_LDFLAGS:-}"
ALPINE_LTP_FILTER_OUT_DIRS="${ALPINE_LTP_FILTER_OUT_DIRS:-fmtmsg timer_create}"
ALPINE_LTP_DOCKER_IMAGE="${ALPINE_LTP_DOCKER_IMAGE:-}"
ALPINE_LTP_DOCKER_INSTALL_PACKAGES="${ALPINE_LTP_DOCKER_INSTALL_PACKAGES:-0}"
ALPINE_LTP_BUILD_PACKAGES=(
    build-base
    linux-headers
    autoconf
    automake
    pkgconf
)
ALPINE_ARCHES=("aarch64" "loongarch64" "riscv64" "x86_64")
ALPINE_DEFAULT_PACKAGES=(
    binutils
    gcc
    musl-dev
    libusb-dev
    git
    vim
)

# Global variables for parsed arguments
ALPINE_URL=""
ALPINE_WORK_DIR=""
ALPINE_ROOTFS_IMG=""
ALPINE_ARCHIVE=""
ALPINE_METADATA_ARCH=""
ALPINE_METADATA_DATE=""
ALPINE_METADATA_FILE=""
ALPINE_METADATA_SHA256=""
ALPINE_METADATA_SHA512=""
ALPINE_METADATA_SIZE=""
ALPINE_METADATA_TIME=""
ALPINE_METADATA_VERSION=""

alpine_release_tag() {
    printf '%s\n' "${ALPINE_REL#v}"
}

alpine_docker_arch_name() {
    local arch="$1"

    case "${arch}" in
        x86_64) printf 'x86_64' ;;
        aarch64) printf 'aarch64' ;;
        riscv64) printf 'riscv64' ;;
        loongarch64) printf 'loongarch64' ;;
        *) die "Unsupported Docker image architecture: ${arch}" ;;
    esac
}

alpine_host_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'aarch64' ;;
        riscv64) printf 'riscv64' ;;
        loongarch64) printf 'loongarch64' ;;
        *) die "Unsupported host architecture for Alpine Docker helper: $(uname -m)" ;;
    esac
}

alpine_base_docker_image_for_arch() {
    local arch="$1"
    printf '%s-%s:%s\n' "${ALPINE_DOCKER_IMAGE_PREFIX}" "$(alpine_docker_arch_name "${arch}")" "$(alpine_release_tag)"
}

alpine_ltp_docker_image_for_arch() {
    local arch="$1"
    printf '%s-%s-ltp:%s\n' "${ALPINE_DOCKER_IMAGE_PREFIX}" "$(alpine_docker_arch_name "${arch}")" "$(alpine_release_tag)"
}

alpine_docker_platform_for_arch() {
    local arch="$1"

    case "${arch}" in
        aarch64) printf 'linux/arm64/v8' ;;
        loongarch64) printf 'linux/loong64' ;;
        riscv64) printf 'linux/riscv64' ;;
        x86_64) printf 'linux/amd64' ;;
        *) die "Unsupported Docker target architecture: ${arch}" ;;
    esac
}

alpine_docker_image_exists() {
    local image="$1"
    docker image inspect "${image}" >/dev/null 2>&1
}

alpine_ensure_base_docker_image() {
    local arch="$1"
    local image="$2"
    local platform
    local source_image="alpine:$(alpine_release_tag)"

    if ! command -v docker >/dev/null 2>&1; then
        die "docker is required to prepare Alpine Docker image ${image}"
    fi

    if alpine_docker_image_exists "${image}"; then
        return 0
    fi

    platform="$(alpine_docker_platform_for_arch "${arch}")"
    info "Pulling Alpine Docker image ${source_image} (${platform}) for ${image}"
    docker pull --platform "${platform}" "${source_image}" >/dev/null
    docker tag "${source_image}" "${image}"
}

alpine_ensure_ltp_docker_image() {
    local arch="$1"
    local image="$2"
    local platform
    local dockerfile="${ALPINE_SCRIPT_DIR}/alpine-ltp.Dockerfile"
    local context_dockerfile
    if ! command -v docker >/dev/null 2>&1; then
        die "docker is required to prepare Alpine LTP Docker image ${image}"
    fi

    if alpine_docker_image_exists "${image}"; then
        return 0
    fi

    alpine_download_archive
    platform="$(alpine_docker_platform_for_arch "${arch}")"
    context_dockerfile="${ALPINE_WORK_DIR}/alpine-ltp.Dockerfile"
    cp -f "${dockerfile}" "${context_dockerfile}"
    info "Building Alpine LTP Docker image ${image} (${platform}) from ${ALPINE_ARCHIVE}"
    docker build \
        --platform "${platform}" \
        -f "${context_dockerfile}" \
        --build-arg "ALPINE_MINIROOTFS=$(basename "${ALPINE_ARCHIVE}")" \
        -t "${image}" \
        "${ALPINE_WORK_DIR}"
}

alpine_usage() {
    printf 'Build Alpine-based rootfs image\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rootfs/alpine.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64                       Build minimal filesystem for aarch64\n'
    printf '  riscv64                       Build minimal filesystem for riscv64\n'
    printf '  x86_64                        Build minimal filesystem for x86_64\n'
    printf '  loongarch64                   Build minimal filesystem for loongarch64\n'
    printf '  all                           Build minimal filesystem for all supported architectures\n'
    printf '  clean                         Clean generated images for all supported architectures\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --out_dir <dir>               Output directory (default image: IMAGES/rootfs/rootfs-<arch>-alpine.img)\n'
    printf '  --guest <dir>                 Guest directory to copy into rootfs /guest\n'
    printf '  --img-size <size>             Output image size (default: 2G)\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  ALPINE_IMG_SIZE               Output image size\n'
    printf '  ALPINE_BASE                   Alpine mirror base URL\n'
    printf '  ALPINE_REL                    Alpine release\n'
    printf '  ALPINE_DOCKER_DNS             Comma-separated DNS servers for Docker apk install (default: 223.5.5.5,114.114.114.114; set empty to disable)\n'
    printf '  ALPINE_DOCKER_IMAGE_PREFIX    Local Docker image prefix (default: tgos/alpine)\n'
    printf '  ALPINE_APK_DOCKER_ARCH        Docker architecture used to run apk --root/--arch (default: x86_64)\n'
    printf '  ALPINE_APK_DOCKER_IMAGE       Docker image used to run apk --root/--arch (default: <prefix>-<apk-arch>:<release>)\n'
    printf '  ALPINE_LTP_URL                LTP source archive URL\n'
    printf '  ALPINE_LTP_CFLAGS             Extra CFLAGS for LTP build\n'
    printf '  ALPINE_LTP_LDFLAGS            Extra LDFLAGS for LTP build\n'
    printf '  ALPINE_LTP_FILTER_OUT_DIRS    LTP syscall directories skipped for Alpine/musl builds\n'
    printf '  ALPINE_LTP_DOCKER_IMAGE       Docker image used to build LTP (default: <prefix>-<target-arch>-ltp:<release>)\n'
    printf '  ALPINE_LTP_DOCKER_INSTALL_PACKAGES Install LTP build packages in container, 1 or 0 (default: 0)\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * Generates rootfs.img only.\n'
    printf '  * Downloads Alpine minirootfs into build/alpine/<arch>/.\n'
    printf '  * The all command currently targets: aarch64, loongarch64, riscv64, x86_64.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rootfs/alpine.sh aarch64\n'
    printf '  scripts/rootfs/alpine.sh all\n'
    printf '  scripts/rootfs/alpine.sh loongarch64 --out_dir /tmp/rootfs\n'
    printf '  scripts/rootfs/alpine.sh riscv64 --out_dir /tmp/rootfs\n'
    printf '  scripts/rootfs/alpine.sh x86_64 --img-size 2G\n'
    printf '  scripts/rootfs/alpine.sh aarch64 --guest /path/to/guest/files\n'
}

alpine_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out_dir)
                ALPINE_OUT_DIR="$2"
                shift 2
                ;;
            --guest)
                ALPINE_GUEST_DIR="$2"
                shift 2
                ;;
            --img-size)
                ALPINE_IMG_SIZE="$2"
                shift 2
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

alpine_init_config() {
    ALPINE_ARCHIVE=""
    ALPINE_METADATA_ARCH=""
    ALPINE_METADATA_DATE=""
    ALPINE_METADATA_FILE=""
    ALPINE_METADATA_SHA256=""
    ALPINE_METADATA_SHA512=""
    ALPINE_METADATA_SIZE=""
    ALPINE_METADATA_TIME=""
    ALPINE_METADATA_VERSION=""

    ALPINE_URL="${ALPINE_BASE}/${ALPINE_REL}/releases/${ALPINE_ARCH}"
    ALPINE_WORK_DIR="${BUILD_DIR}/alpine/${ALPINE_ARCH}"
    local output_dir="${ALPINE_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    ALPINE_ROOTFS_IMG="${output_dir}/rootfs-${ALPINE_ARCH}-alpine.img"

    if [[ -n "${ALPINE_GUEST_DIR}" ]]; then
        ALPINE_GUEST_DIR="$(cd "${ALPINE_GUEST_DIR}" 2>/dev/null && pwd -P)" || {
            warn "Guest directory ${ALPINE_GUEST_DIR} does not exist or is not accessible"
            ALPINE_GUEST_DIR=""
        }
    fi

    mkdir -p "${ALPINE_WORK_DIR}" "$(dirname "${ALPINE_ROOTFS_IMG}")"
}

alpine_fetch_release_metadata() {
    curl -fsSL "${ALPINE_URL}/latest-releases.yaml" | awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            sub(/^'\''/, "", value)
            sub(/'\''$/, "", value)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            return value
        }

        function reset_entry() {
            entry_arch = ""
            entry_date = ""
            entry_file = ""
            entry_flavor = ""
            entry_sha256 = ""
            entry_sha512 = ""
            entry_size = ""
            entry_time = ""
            entry_version = ""
        }

        function emit_entry() {
            if (entry_flavor != "alpine-minirootfs") {
                return
            }

            print "arch=" entry_arch
            print "date=" entry_date
            print "file=" entry_file
            print "sha256=" entry_sha256
            print "sha512=" entry_sha512
            print "size=" entry_size
            print "time=" entry_time
            print "version=" entry_version
            found = 1
            exit
        }

        function parse_line(line, pos, key, value) {
            pos = index(line, ":")
            if (!pos) {
                return
            }

            key = trim(substr(line, 1, pos - 1))
            value = trim(substr(line, pos + 1))

            if (key == "arch") entry_arch = value
            else if (key == "date") entry_date = value
            else if (key == "file") entry_file = value
            else if (key == "flavor") entry_flavor = value
            else if (key == "sha256") entry_sha256 = value
            else if (key == "sha512") entry_sha512 = value
            else if (key == "size") entry_size = value
            else if (key == "time") entry_time = value
            else if (key == "version") entry_version = value
        }

        BEGIN {
            found = 0
            seen_entry = 0
            reset_entry()
        }

        /^-[[:space:]]*$/ {
            if (seen_entry) {
                emit_entry()
            }
            reset_entry()
            seen_entry = 1
            next
        }

        /^- / {
            if (seen_entry) {
                emit_entry()
            }
            reset_entry()
            seen_entry = 1
            parse_line(substr($0, 3))
            next
        }

        /^[[:space:]]+[[:alnum:]_-]+:/ {
            parse_line($0)
            next
        }

        END {
            if (!found && seen_entry) {
                emit_entry()
            }
            if (!found) {
                exit 1
            }
        }
    '
}

alpine_load_release_metadata() {
    local metadata key value

    metadata="$(alpine_fetch_release_metadata)" || {
        die "Failed to fetch Alpine release metadata from ${ALPINE_URL}/latest-releases.yaml"
    }

    while IFS='=' read -r key value; do
        case "${key}" in
            arch) ALPINE_METADATA_ARCH="${value}" ;;
            date) ALPINE_METADATA_DATE="${value}" ;;
            file) ALPINE_METADATA_FILE="${value}" ;;
            sha256) ALPINE_METADATA_SHA256="${value}" ;;
            sha512) ALPINE_METADATA_SHA512="${value}" ;;
            size) ALPINE_METADATA_SIZE="${value}" ;;
            time) ALPINE_METADATA_TIME="${value}" ;;
            version) ALPINE_METADATA_VERSION="${value}" ;;
        esac
    done <<< "${metadata}"

    if [[ -z "${ALPINE_METADATA_FILE}" || -z "${ALPINE_METADATA_SHA256}" ]]; then
        die "Incomplete Alpine release metadata for ${ALPINE_ARCH} from ${ALPINE_URL}/latest-releases.yaml"
    fi

    ALPINE_ARCHIVE="${ALPINE_WORK_DIR}/${ALPINE_METADATA_FILE}"
}

alpine_ltp_archive_path() {
    printf '%s/ltp/%s\n' "${BUILD_DIR}" "$(basename "${ALPINE_LTP_URL%%\?*}")"
}

alpine_ltp_src_dir() {
    local archive_name
    archive_name="$(basename "${ALPINE_LTP_URL%%\?*}")"
    archive_name="${archive_name%.tar.xz}"
    archive_name="${archive_name%.tar.gz}"
    archive_name="${archive_name%.tgz}"
    printf '%s/ltp/%s\n' "${BUILD_DIR}" "${archive_name}"
}

alpine_ltp_docker_platform_for_arch() {
    local arch="$1"

    alpine_docker_platform_for_arch "${arch}"
}

alpine_ltp_prepare_source() {
    local archive_path
    local src_dir
    local src_parent

    archive_path="$(alpine_ltp_archive_path)"
    src_dir="$(alpine_ltp_src_dir)"
    src_parent="$(dirname "${src_dir}")"
    mkdir -p "${src_parent}"

    if [[ -f "${archive_path}" ]]; then
        info "Using cached LTP archive: ${archive_path}"
    else
        info "Downloading LTP archive: ${ALPINE_LTP_URL}"
        curl -# -L -o "${archive_path}" "${ALPINE_LTP_URL}"
    fi

    if [[ -d "${src_dir}" ]]; then
        printf '%s\n' "${src_dir}"
        return 0
    fi

    info "Extracting LTP archive to ${src_parent}"
    tar -xf "${archive_path}" -C "${src_parent}"

    if [[ ! -d "${src_dir}" ]]; then
        die "LTP source directory not found after extraction: ${src_dir}"
    fi

    printf '%s\n' "${src_dir}"
}

alpine_install_ltp_syscalls() {
    local rootfs_dir="$1"
    local ltp_src_dir="${2:-}"
    local host_uid
    local host_gid
    local docker_platform
    local docker_dns_servers=()
    local docker_dns_args=()
    local dns_server
    local ltp_docker_image="${ALPINE_LTP_DOCKER_IMAGE:-$(alpine_ltp_docker_image_for_arch "${ALPINE_ARCH}")}"
    local ltp_runtest_filter_pattern=""
    local filter_dir

    ltp_src_dir="${ltp_src_dir:-$(alpine_ltp_prepare_source)}"

    if ! command -v docker >/dev/null 2>&1; then
        die "docker is required to build LTP syscall tests"
    fi

    if [[ -n "${ALPINE_DOCKER_DNS}" ]]; then
        IFS=',' read -r -a docker_dns_servers <<< "${ALPINE_DOCKER_DNS}"
    fi
    for dns_server in "${docker_dns_servers[@]}"; do
        [[ -n "${dns_server}" ]] || continue
        docker_dns_args+=("--dns" "${dns_server}")
    done

    host_uid="$(id -u)"
    host_gid="$(id -g)"
    docker_platform="$(alpine_ltp_docker_platform_for_arch "${ALPINE_ARCH}")"
    alpine_ensure_ltp_docker_image "${ALPINE_ARCH}" "${ltp_docker_image}"
    for filter_dir in ${ALPINE_LTP_FILTER_OUT_DIRS}; do
        [[ -n "${filter_dir}" ]] || continue
        if [[ -z "${ltp_runtest_filter_pattern}" ]]; then
            ltp_runtest_filter_pattern="^${filter_dir}([0-9_]|[[:space:]]|$)"
        else
            ltp_runtest_filter_pattern="${ltp_runtest_filter_pattern}|^${filter_dir}([0-9_]|[[:space:]]|$)"
        fi
    done

    info "Installing LTP syscall tests in Docker (${docker_platform}, ${ltp_docker_image})"
    docker run --rm \
        "${docker_dns_args[@]}" \
        --platform "${docker_platform}" \
        -v "${ltp_src_dir}:/ltp" \
        -v "${rootfs_dir}:/rootfs" \
        -w /ltp \
        "${ltp_docker_image}" \
        sh -lc "
            set -e
            trap 'chown -R ${host_uid}:${host_gid} /rootfs /ltp >/dev/null 2>&1 || true' EXIT
            if [ '${ALPINE_LTP_DOCKER_INSTALL_PACKAGES}' = '1' ]; then
                apk add --no-cache ${ALPINE_LTP_BUILD_PACKAGES[*]}
            fi
            if [ -x ./autogen.sh ] && [ ! -x ./configure ]; then
                ./autogen.sh
            elif [ ! -x ./configure ]; then
                make autotools
            fi
            make clean >/dev/null 2>&1 || true
            rm -f include/mk/config.mk include/mk/config-openposix.mk include/mk/features.mk include/config.h config.status
            CFLAGS='${ALPINE_LTP_CFLAGS}' \
            LDFLAGS='${ALPINE_LTP_LDFLAGS}' \
            ./configure \
                --prefix='${ALPINE_LTP_PREFIX}' \
                --without-numa \
                --without-tirpc \
                --without-modules
            if printf '#include <linux/if_alg.h>
int main(void){struct sockaddr_alg a; struct af_alg_iv v; return sizeof(a)+sizeof(v);}
' | gcc -x c -c -o /tmp/ltp-if-alg.o - >/dev/null 2>&1; then
                sed -i \
                    -e 's@^/\* #undef HAVE_LINUX_IF_ALG_H \*/@#define HAVE_LINUX_IF_ALG_H 1@' \
                    -e 's@^/\* #undef HAVE_STRUCT_AF_ALG_IV \*/@#define HAVE_STRUCT_AF_ALG_IV 1@' \
                    -e 's@^/\* #undef HAVE_STRUCT_SOCKADDR_ALG \*/@#define HAVE_STRUCT_SOCKADDR_ALG 1@' \
                    include/config.h
            else
                sed -i \
                    -e 's@^#define HAVE_STRUCT_AF_ALG_IV .*@/* #undef HAVE_STRUCT_AF_ALG_IV */@' \
                    -e 's@^#define HAVE_STRUCT_SOCKADDR_ALG .*@/* #undef HAVE_STRUCT_SOCKADDR_ALG */@' \
                    include/config.h
            fi
            make -C testcases/kernel/syscalls \
                top_srcdir=/ltp \
                top_builddir=/ltp \
                FILTER_OUT_DIRS='${ALPINE_LTP_FILTER_OUT_DIRS}'
            make -C testcases/kernel/syscalls \
                top_srcdir=/ltp \
                top_builddir=/ltp \
                FILTER_OUT_DIRS='${ALPINE_LTP_FILTER_OUT_DIRS}' \
                DESTDIR=/rootfs \
                install
            mkdir -p '/rootfs${ALPINE_LTP_PREFIX}/runtest'
            if [ -n '${ltp_runtest_filter_pattern}' ]; then
                grep -v -E '${ltp_runtest_filter_pattern}' runtest/syscalls > '/rootfs${ALPINE_LTP_PREFIX}/runtest/syscalls'
            else
                cp -f runtest/syscalls '/rootfs${ALPINE_LTP_PREFIX}/runtest/syscalls'
            fi
        "
}

alpine_write_overlay_files() {
    local rootfs_dir="$1"

    mkdir -p "${rootfs_dir}/etc/X11"

    printf '%s\n' 'starry' > "${rootfs_dir}/etc/hostname"

    cat > "${rootfs_dir}/etc/resolv.conf" <<'EOF'
# SLIRP default DNS server
# See https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP)
nameserver 10.0.2.3
EOF

    if [[ "${ALPINE_ARCH}" == "loongarch64" ]]; then
        mkdir -p "${rootfs_dir}/etc/init.d" \
            "${rootfs_dir}/dev" \
            "${rootfs_dir}/proc" \
            "${rootfs_dir}/sys"

        cat > "${rootfs_dir}/etc/inittab" <<'EOF'
# /etc/inittab - BusyBox init for TGOS Alpine rootfs
::sysinit:/etc/init.d/rcS
ttyS0::respawn:/bin/sh
ttyAMA0::respawn:/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

        cat > "${rootfs_dir}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mkdir -p /proc /sys /dev /dev/pts /tmp /run
mount -t proc proc /proc >/dev/null 2>&1 || true
mount -t sysfs sysfs /sys >/dev/null 2>&1 || true
mount -t devtmpfs devtmpfs /dev >/dev/null 2>&1 || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts >/dev/null 2>&1 || true

hostname -F /etc/hostname >/dev/null 2>&1 || true
EOF
        chmod +x "${rootfs_dir}/etc/init.d/rcS"

        ln -sf /bin/busybox "${rootfs_dir}/sbin/init"
        mknod "${rootfs_dir}/dev/console" c 5 1 2>/dev/null || true
        mknod "${rootfs_dir}/dev/null" c 1 3 2>/dev/null || true
        mknod "${rootfs_dir}/dev/ttyS0" c 4 64 2>/dev/null || true
        mknod "${rootfs_dir}/dev/ttyAMA0" c 204 64 2>/dev/null || true
    fi

    cat > "${rootfs_dir}/etc/X11/xorg.conf" <<'EOF'
Section "Device"
    Identifier "MyFramebuffer"
    Driver "fbdev"
    Option "SWCursor" "on"
    Option "fbdev" "/dev/fb0"
EndSection

Section "Screen"
    Identifier "Default Screen"
    Device "MyFramebuffer"
    Monitor "Generic Monitor"
EndSection

Section "Monitor"
    Identifier "Generic Monitor"
EndSection

Section "ServerLayout"
    Identifier "Default Layout"
    Screen 0 "Default Screen"
    Option "AutoAddDevices" "false"
    InputDevice "Keyboard0" "CoreKeyboard"
    InputDevice "Mouse0" "CorePointer"
EndSection

Section "InputDevice"
    Identifier "Keyboard0"
    Driver "evdev"
    Option "Device" "/dev/input/event0"
EndSection

Section "InputDevice"
    Identifier "Mouse0"
    Driver "evdev"
    Option "Device" "/dev/input/mice"
EndSection
EOF
}

alpine_copy_guest_dir() {
    local rootfs_dir="$1"

    if [[ -z "${ALPINE_GUEST_DIR}" ]]; then
        return 0
    fi

    if [[ ! -d "${ALPINE_GUEST_DIR}" ]]; then
        warn "Guest directory ${ALPINE_GUEST_DIR} does not exist, skipping..."
        return 0
    fi

    info "Copying guest directory: ${ALPINE_GUEST_DIR} -> ${rootfs_dir}/guest/"
    mkdir -p "${rootfs_dir}/guest"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${ALPINE_GUEST_DIR}/" "${rootfs_dir}/guest/" 2>/dev/null || true
    else
        cp -a "${ALPINE_GUEST_DIR}/." "${rootfs_dir}/guest/" 2>/dev/null || true
    fi
}

alpine_install_default_packages() {
    local rootfs_dir="$1"
    local host_uid
    local host_gid
    local helper_arch
    local apk_docker_image
    local docker_platform
    local docker_dns_servers=()
    local docker_dns_args=()
    local dns_server
    local apk_args=(
        --root "${rootfs_dir}"
        --arch "${ALPINE_ARCH}"
        --repositories-file "${rootfs_dir}/etc/apk/repositories"
        --keys-dir "${rootfs_dir}/etc/apk/keys"
        --no-cache
        --update-cache
        --no-scripts
        add
        "${ALPINE_DEFAULT_PACKAGES[@]}"
    )

    if [[ -n "${ALPINE_DOCKER_DNS}" ]]; then
        IFS=',' read -r -a docker_dns_servers <<< "${ALPINE_DOCKER_DNS}"
    fi

    info "Installing default Alpine packages: ${ALPINE_DEFAULT_PACKAGES[*]}"
    if command -v apk >/dev/null 2>&1; then
        cp -f /etc/resolv.conf "${rootfs_dir}/etc/resolv.conf"
        apk "${apk_args[@]}"
        return
    fi

    if ! command -v docker >/dev/null 2>&1; then
        die "Neither apk nor docker is available to install default Alpine packages"
    fi

    host_uid="$(id -u)"
    host_gid="$(id -g)"
    helper_arch="${ALPINE_APK_DOCKER_ARCH}"
    apk_docker_image="${ALPINE_APK_DOCKER_IMAGE:-$(alpine_base_docker_image_for_arch "${helper_arch}")}"
    docker_platform="$(alpine_docker_platform_for_arch "${helper_arch}")"
    alpine_ensure_base_docker_image "${helper_arch}" "${apk_docker_image}"

    for dns_server in "${docker_dns_servers[@]}"; do
        [[ -n "${dns_server}" ]] || continue
        docker_dns_args+=("--dns" "${dns_server}")
    done

    docker run --rm \
        "${docker_dns_args[@]}" \
        --platform "${docker_platform}" \
        -v "${rootfs_dir}:/rootfs" \
        "${apk_docker_image}" \
        sh -lc "
            set -e
            cp -f /etc/resolv.conf /rootfs/etc/resolv.conf
            apk \
                --root /rootfs \
                --arch '${ALPINE_ARCH}' \
                --repositories-file /rootfs/etc/apk/repositories \
                --keys-dir /rootfs/etc/apk/keys \
                --no-cache \
                --update-cache \
                --no-scripts \
                add ${ALPINE_DEFAULT_PACKAGES[*]}
            chown -R ${host_uid}:${host_gid} /rootfs
        "
}

alpine_cleanup_rootfs_dir() {
    local rootfs_dir="$1"

    [[ -d "${rootfs_dir}" ]] || return 0
    rm -rf "${rootfs_dir}" && return 0

    warn "Local cleanup failed for ${rootfs_dir}, retrying via Docker"
    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker is unavailable, leaving temporary directory behind: ${rootfs_dir}"
        return 0
    fi

    docker run --rm \
        -v "$(dirname "${rootfs_dir}"):/work" \
        "alpine:${ALPINE_REL#v}" \
        sh -lc "rm -rf '/work/$(basename "${rootfs_dir}")'" >/dev/null 2>&1 || \
        warn "Failed to clean temporary directory via Docker: ${rootfs_dir}"
}

alpine_download_archive() {
    if [[ -f "${ALPINE_ARCHIVE}" ]]; then
        info "Using cached Alpine minirootfs archive: ${ALPINE_ARCHIVE}"
    else
        info "Downloading ${ALPINE_METADATA_FILE}..."
        info "Arch: ${ALPINE_METADATA_ARCH}"
        info "Version: ${ALPINE_METADATA_VERSION}"
        info "Date: ${ALPINE_METADATA_DATE}"
        info "Time: ${ALPINE_METADATA_TIME}"
        info "Size: $(numfmt --to=iec "${ALPINE_METADATA_SIZE}") (${ALPINE_METADATA_SIZE} bytes)"
        curl -# -L -o "${ALPINE_ARCHIVE}" "${ALPINE_URL}/${ALPINE_METADATA_FILE}"
    fi

    info "Verifying ${ALPINE_METADATA_FILE}..."
    echo "${ALPINE_METADATA_SHA256}  ${ALPINE_ARCHIVE}" | sha256sum -c -
}

alpine_create_rootfs() {
    local rootfs_dir
    local rootfs_img_tmp="${ALPINE_ROOTFS_IMG}.tmp.$$"
    rootfs_dir="$(mktemp -d "${ALPINE_WORK_DIR}/rootfs.XXXXXX")"
    trap 'alpine_cleanup_rootfs_dir "'"${rootfs_dir}"'"; rm -f "'"${rootfs_img_tmp}"'"' EXIT

    info "Creating Alpine rootfs image ${ALPINE_ROOTFS_IMG} (${ALPINE_IMG_SIZE})"
    rm -f "${rootfs_img_tmp}"
    fallocate -v -l "${ALPINE_IMG_SIZE}" "${rootfs_img_tmp}"
    mkfs.ext4 -v -O ^metadata_csum -F "${rootfs_img_tmp}"
    fsck.ext4 -v -p -f "${rootfs_img_tmp}"

    info "Extracting ${ALPINE_METADATA_FILE} to ${ALPINE_ROOTFS_IMG}..."
    tar -xzf "${ALPINE_ARCHIVE}" -C "${rootfs_dir}"

    alpine_copy_guest_dir "${rootfs_dir}"

    sed -i "s#https\?://dl-cdn.alpinelinux.org/alpine#${ALPINE_BASE}#g" \
        "${rootfs_dir}/etc/apk/repositories"
    alpine_install_default_packages "${rootfs_dir}"
    alpine_write_overlay_files "${rootfs_dir}"
    alpine_install_ltp_syscalls "${rootfs_dir}"

    if ! command -v debugfs >/dev/null 2>&1; then
        die "debugfs not found. Please install e2fsprogs"
    fi

    info "Writing Alpine rootfs into ext4 image via debugfs..."
    (
        cd "${rootfs_dir}"

        find . -type d | while read -r d; do
            debugfs -w -R "mkdir ${d#.}" "${rootfs_img_tmp}" >/dev/null 2>&1
        done

        find . -type f | while read -r f; do
            debugfs -w -R "write $f ${f#.}" "${rootfs_img_tmp}" >/dev/null 2>&1
        done

        find . -type l | while read -r lnk; do
            target=$(readlink "$lnk")
            debugfs -w -R "symlink ${lnk#.} $target" "${rootfs_img_tmp}" >/dev/null 2>&1
        done
    )

    mv -f "${rootfs_img_tmp}" "${ALPINE_ROOTFS_IMG}"
    trap - EXIT
    alpine_cleanup_rootfs_dir "${rootfs_dir}"

    success "Alpine rootfs created: ${ALPINE_ROOTFS_IMG}"
}

alpine() {
    alpine_init_config
    alpine_load_release_metadata
    alpine_download_archive
    alpine_create_rootfs
}

alpine_clean_outputs() {
    local output_dir="${ALPINE_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    rm -f \
        "${output_dir}/rootfs-aarch64-alpine.img" \
        "${output_dir}/rootfs-loongarch64-alpine.img" \
        "${output_dir}/rootfs-riscv64-alpine.img" \
        "${output_dir}/rootfs-x86_64-alpine.img"
    success "Alpine rootfs outputs cleaned in ${output_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            alpine_usage
            exit 0
            ;;
        aarch64|loongarch64|riscv64|x86_64)
            alpine_parse_args "$@"
            ALPINE_ARCH="$cmd"
            alpine
            ;;
        all)
            alpine_parse_args "$@"
            if [[ -n "${ALPINE_OUT_DIR}" ]]; then
                die "--out_dir can only be used for a single architecture build"
            fi

            for arch in "${ALPINE_ARCHES[@]}"; do
                ALPINE_ARCH="${arch}"
                alpine
            done
            ;;
        clean)
            alpine_parse_args "$@"
            alpine_clean_outputs
            ;;
        *)
            die "Unknown command: $cmd"
            ;;
    esac
fi
