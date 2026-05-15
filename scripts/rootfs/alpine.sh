#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

# Default values
ALPINE_ARCH=""
ALPINE_OUT_DIR=""
ALPINE_GUEST_DIR=""
ALPINE_IMG_SIZE="${ALPINE_IMG_SIZE:-1G}"
ALPINE_BASE="${ALPINE_BASE:-https://mirrors.tuna.tsinghua.edu.cn/alpine}"
ALPINE_REL="${ALPINE_REL:-v3.23}"
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
    printf '  --img-size <size>             Output image size (default: 1G)\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  ALPINE_IMG_SIZE               Output image size\n'
    printf '  ALPINE_BASE                   Alpine mirror base URL\n'
    printf '  ALPINE_REL                    Alpine release\n'
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

alpine_write_overlay_files() {
    local rootfs_dir="$1"

    mkdir -p "${rootfs_dir}/etc/X11"

    printf '%s\n' 'starry' > "${rootfs_dir}/etc/hostname"

    cat > "${rootfs_dir}/etc/resolv.conf" <<'EOF'
# SLIRP default DNS server
# See https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP)
nameserver 10.0.2.3
EOF

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
    local docker_platform
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

    info "Installing default Alpine packages: ${ALPINE_DEFAULT_PACKAGES[*]}"
    if command -v apk >/dev/null 2>&1; then
        apk "${apk_args[@]}"
        return
    fi

    if ! command -v docker >/dev/null 2>&1; then
        die "Neither apk nor docker is available to install default Alpine packages"
    fi

    host_uid="$(id -u)"
    host_gid="$(id -g)"
    case "$(uname -m)" in
        x86_64) docker_platform="linux/amd64" ;;
        aarch64|arm64) docker_platform="linux/arm64/v8" ;;
        riscv64) docker_platform="linux/riscv64" ;;
        loongarch64) docker_platform="linux/loong64" ;;
        *) docker_platform="" ;;
    esac

    docker run --rm \
        ${docker_platform:+--platform "${docker_platform}"} \
        -v "${rootfs_dir}:/rootfs" \
        "alpine:${ALPINE_REL#v}" \
        sh -lc "
            set -e
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
    rootfs_dir="$(mktemp -d "${ALPINE_WORK_DIR}/rootfs.XXXXXX")"
    trap 'alpine_cleanup_rootfs_dir "'"${rootfs_dir}"'"' EXIT

    info "Creating Alpine rootfs image ${ALPINE_ROOTFS_IMG} (${ALPINE_IMG_SIZE})"
    rm -f "${ALPINE_ROOTFS_IMG}"
    fallocate -v -l "${ALPINE_IMG_SIZE}" "${ALPINE_ROOTFS_IMG}"
    mkfs.ext4 -v -O ^metadata_csum -F "${ALPINE_ROOTFS_IMG}"
    fsck.ext4 -v -p -f "${ALPINE_ROOTFS_IMG}"

    info "Extracting ${ALPINE_METADATA_FILE} to ${ALPINE_ROOTFS_IMG}..."
    tar -xzf "${ALPINE_ARCHIVE}" -C "${rootfs_dir}"

    alpine_copy_guest_dir "${rootfs_dir}"
    alpine_write_overlay_files "${rootfs_dir}"

    sed -i "s#https\?://dl-cdn.alpinelinux.org/alpine#${ALPINE_BASE}#g" \
        "${rootfs_dir}/etc/apk/repositories"
    alpine_install_default_packages "${rootfs_dir}"

    if ! command -v debugfs >/dev/null 2>&1; then
        die "debugfs not found. Please install e2fsprogs"
    fi

    info "Writing Alpine rootfs into ext4 image via debugfs..."
    (
        cd "${rootfs_dir}"

        find . -type d | while read -r d; do
            debugfs -w -R "mkdir ${d#.}" "${ALPINE_ROOTFS_IMG}" >/dev/null 2>&1
        done

        find . -type f | while read -r f; do
            debugfs -w -R "write $f ${f#.}" "${ALPINE_ROOTFS_IMG}" >/dev/null 2>&1
        done

        find . -type l | while read -r lnk; do
            target=$(readlink "$lnk")
            debugfs -w -R "symlink ${lnk#.} $target" "${ALPINE_ROOTFS_IMG}" >/dev/null 2>&1
        done
    )

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
