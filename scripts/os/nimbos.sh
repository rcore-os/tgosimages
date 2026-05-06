#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

# Default values
NIMBOS_REPO_URL="${NIMBOS_REPO_URL:-https://github.com/arceos-hypervisor/nimbos.git}"
NIMBOS_REF="${NIMBOS_REF:-8621b11dae9d90de985758358396ff3844c9c513}"
NIMBOS_SRC_DIR="${NIMBOS_SRC_DIR:-${BUILD_DIR}/nimbos}"
AXVM_BIOS_X86_REPO_URL="${AXVM_BIOS_X86_REPO_URL:-https://github.com/arceos-hypervisor/axvm-bios-x86.git}"
AXVM_BIOS_X86_REF="${AXVM_BIOS_X86_REF:-667c70808be2307f99523e81491d255a1844c703}"
AXVM_BIOS_X86_SRC_DIR="${AXVM_BIOS_X86_SRC_DIR:-${BUILD_DIR}/axvm-bios-x86}"

# Global variables for parsed arguments
NIMBOS_PLATFORM=""
NIMBOS_ARGS=""
NIMBOS_IMAGES_DIR=""
NIMBOS_IMAGE_NAME=""

nimbos_usage() {
    printf 'NimbOS build script for various platforms\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/nimbos.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64                           Build for aarch64 platform\n'
    printf '  x86_64                            Build for x86_64 platform\n'
    printf '  riscv64                           Build for riscv64 platform\n'
    printf '  all                               Build all supported platforms\n'
    printf '  clean                             Clean all supported platforms\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --repo-url <url>                  NimbOS repository URL (default: https://github.com/arceos-hypervisor/nimbos.git)\n'
    printf '  --src-dir <dir>                   Source directory (default: build/nimbos)\n'
    printf '  --bios-repo-url <url>             AXVM BIOS repository URL (default: https://github.com/arceos-hypervisor/axvm-bios-x86.git)\n'
    printf '  --bios-src-dir <dir>              AXVM BIOS source directory (default: build/axvm-bios-x86)\n'
    printf '  --images-dir <dir>                Output images directory (default: IMAGES/nimbos/<arch>/nimbos)\n'
    printf '  --image-name <name>               Output image name (default: current command)\n'
    printf '  The other options will be directly passed to the make build system. for example:\n'
    printf '     clean                          Clean for specific platform\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  NIMBOS_REPO_URL                   NimbOS repository URL\n'
    printf '  NIMBOS_REF                        NimbOS git commit/ref\n'
    printf '  NIMBOS_SRC_DIR                    NimbOS source directory\n'
    printf '  AXVM_BIOS_X86_REPO_URL            AXVM BIOS repository URL\n'
    printf '  AXVM_BIOS_X86_REF                 AXVM BIOS git commit/ref\n'
    printf '  AXVM_BIOS_X86_SRC_DIR             AXVM BIOS source directory\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/nimbos.sh aarch64\n'
    printf '  scripts/nimbos.sh x86_64 clean\n'
}

nimbos_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo-url)
                NIMBOS_REPO_URL="$2"
                shift 2
                ;;
            --src-dir)
                NIMBOS_SRC_DIR="$2"
                shift 2
                ;;
            --bios-repo-url)
                AXVM_BIOS_X86_REPO_URL="$2"
                shift 2
                ;;
            --bios-src-dir)
                AXVM_BIOS_X86_SRC_DIR="$2"
                shift 2
                ;;
            --images-dir)
                NIMBOS_IMAGES_DIR="$2"
                shift 2
                ;;
            --image-name)
                NIMBOS_IMAGE_NAME="$2"
                shift 2
                ;;
            *)
                NIMBOS_ARGS="$NIMBOS_ARGS $1"
                shift
                ;;
        esac
    done
}

build_nimbos() {
    if [[ -z "$NIMBOS_IMAGES_DIR" ]]; then
        NIMBOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/nimbos/${NIMBOS_PLATFORM}/nimbos"
    fi

    # Check if clean command
    if [[ "$NIMBOS_ARGS" == *"clean"* ]]; then
        if [[ -d "$NIMBOS_SRC_DIR" ]]; then
            pushd "$NIMBOS_SRC_DIR" >/dev/null
            info "Cleaning NimbOS: make -C kernel clean"
            make -C kernel clean ARCH="${NIMBOS_PLATFORM}" || true
            info "Cleaning user: make -C user clean"
            make -C user clean ARCH="${NIMBOS_PLATFORM}" || true
            popd >/dev/null
        else
            info "Skipping NimbOS source clean; source directory not found: ${NIMBOS_SRC_DIR}"
        fi
        
        # Clean BIOS for x86_64
        if [ "${NIMBOS_PLATFORM}" == "x86_64" ] && [ -d "$AXVM_BIOS_X86_SRC_DIR" ]; then
            pushd "$AXVM_BIOS_X86_SRC_DIR" >/dev/null
            info "Cleaning AXVM BIOS: make clean"
            make clean || true
            popd >/dev/null
        fi
        
        info "Removing ${NIMBOS_IMAGES_DIR}/*"
        rm -rf "${NIMBOS_IMAGES_DIR}"/* || true
        return 0
    fi

    mkdir -p "$NIMBOS_IMAGES_DIR"

    # Build axvm-bios-x86 for x86_64 architecture
    if [ "${NIMBOS_PLATFORM}" == "x86_64" ]; then
        info "Building axvm-bios-x86 for x86_64..."
        axvm_bios_x86
    fi

    pushd "$NIMBOS_SRC_DIR" >/dev/null

    # Install musl toolchain
    local musl_prefix=""
    local musl_path=""
    case "${NIMBOS_PLATFORM}" in
        x86_64)
            musl_prefix="x86_64-linux-musl"
            musl_path="x86_64-linux-musl-cross"
            ;;
        aarch64)
            musl_prefix="aarch64-linux-musl"
            musl_path="aarch64-linux-musl-cross"
            ;;
        riscv64)
            musl_prefix="riscv64-linux-musl"
            musl_path="riscv64-linux-musl-cross"
            ;;
    esac

    # Check if musl toolchain is available
    if ! command -v ${musl_prefix}-gcc &> /dev/null; then
        warn "musl toolchain ${musl_prefix}-gcc not found in PATH"
        
        # Try to download and install musl toolchain
        local musl_dir="${BUILD_DIR}/musl-${NIMBOS_PLATFORM}"
        if [ ! -d "$musl_dir" ]; then
            info "Downloading musl toolchain from https://musl.cc/${musl_path}.tgz"
            
            pushd "${BUILD_DIR}" >/dev/null
            if wget -q "https://musl.cc/${musl_path}.tgz"; then
                info "Extracting musl toolchain..."
                tar -xf "${musl_path}.tgz"
                mv "${musl_path}" "musl-${NIMBOS_PLATFORM}"
                rm -f "${musl_path}.tgz"
                success "musl toolchain installed to ${musl_dir}"
            else
                warn "Failed to download musl toolchain, attempting to build without it..."
            fi
            popd >/dev/null
        fi
        
        # Add musl toolchain to PATH if it exists
        if [ -d "$musl_dir/bin" ]; then
            export PATH="$musl_dir/bin:$PATH"
            info "Added musl toolchain to PATH: $musl_dir/bin"
        fi
    else
        info "musl toolchain ${musl_prefix}-gcc found in PATH"
    fi

    # Build user programs
    info "Building user programs: make -C user build ARCH=${NIMBOS_PLATFORM}"
    make -C user build ARCH="${NIMBOS_PLATFORM}" ${NIMBOS_ARGS}

    # Build kernel (standard build)
    info "Building kernel: make -C kernel build ARCH=${NIMBOS_PLATFORM}"
    make -C kernel build ARCH="${NIMBOS_PLATFORM}" ${NIMBOS_ARGS}

    # Copy the standard build binary
    local binary_path="$NIMBOS_SRC_DIR/kernel/target/${NIMBOS_PLATFORM}/release/nimbos.bin"
    info "Copying: $binary_path -> $NIMBOS_IMAGES_DIR/${NIMBOS_IMAGE_NAME}"
    cp -f "$binary_path" "$NIMBOS_IMAGES_DIR/${NIMBOS_IMAGE_NAME}"

    # Build kernel for usertests
    info "Building kernel for usertests: make -C kernel build ARCH=${NIMBOS_PLATFORM} USER_ENTRY=usertests"
    make -C kernel build ARCH="${NIMBOS_PLATFORM}" USER_ENTRY=usertests ${NIMBOS_ARGS}

    local binary_path="$NIMBOS_SRC_DIR/kernel/target/${NIMBOS_PLATFORM}/release/nimbos.bin"
    info "Copying: $binary_path -> $NIMBOS_IMAGES_DIR/${NIMBOS_IMAGE_NAME}-usertests"
    cp -f "$binary_path" "$NIMBOS_IMAGES_DIR/${NIMBOS_IMAGE_NAME}-usertests"

    popd >/dev/null

    # Create disk image for NimbOS
    info "Creating NimbOS disk image..."
    create_nimbos_disk_image
    
    success "NimbOS build completed successfully"
}

axvm_bios_x86() {
    info "Cloning axvm-bios-x86 source repository $AXVM_BIOS_X86_REPO_URL -> $AXVM_BIOS_X86_SRC_DIR"
    clone_repository "$AXVM_BIOS_X86_REPO_URL" "$AXVM_BIOS_X86_SRC_DIR"
    info "Checking out axvm-bios-x86 ref ${AXVM_BIOS_X86_REF}"
    checkout_ref "$AXVM_BIOS_X86_SRC_DIR" "$AXVM_BIOS_X86_REF"

    info "Starting to build axvm-bios-x86..."
    build_axvm_bios_x86 ${NIMBOS_ARGS}
}

build_axvm_bios_x86() {
    pushd "$AXVM_BIOS_X86_SRC_DIR" >/dev/null
    info "Building axvm-bios-x86: make"
    make
    popd >/dev/null

    # Copy the built BIOS binary
    local bios_bin="$AXVM_BIOS_X86_SRC_DIR/out/axvm-bios.bin"
    
    if [[ ! -f "$bios_bin" ]]; then
        die "axvm-bios.bin not found: ${bios_bin}"
    fi

    mkdir -p "$NIMBOS_IMAGES_DIR"
    info "Copying axvm-bios.bin -> $NIMBOS_IMAGES_DIR/"
    cp "$bios_bin" "$NIMBOS_IMAGES_DIR/axvm-bios.bin"
    
    success "axvm-bios-x86 build completed successfully"
}

create_nimbos_disk_image() {
    local disk_image_path="${NIMBOS_IMAGES_DIR}/${NIMBOS_IMAGE_NAME}.img"
    local nimbos_binary="${NIMBOS_IMAGES_DIR}/${NIMBOS_IMAGE_NAME}-usertests"
    local mount_point="${BUILD_DIR}/nimbos_mount_${NIMBOS_PLATFORM}"
    
    # Check if nimbos binary exists
    if [ ! -f "$nimbos_binary" ]; then
        die "NimbOS usertests binary not found: $nimbos_binary"
    fi
    
    info "Creating disk image: $disk_image_path"
    
    # Create a 64MB disk image (adjust size as needed)
    local disk_size_mb=64
    dd if=/dev/zero of="$disk_image_path" bs=1M count=$disk_size_mb status=progress
    
    # Format with ext4 filesystem
    info "Formatting disk image with ext4..."
    mkfs.fat -F 32 "$disk_image_path"
    
    # Mount and copy NimbOS binary
    info "Mounting disk image and copying NimbOS binary..."
    
    sudo rm -rf "$mount_point"
    sudo mkdir -p "$mount_point"
    
    # Mount the disk image
    sudo mount -o loop "$disk_image_path" "$mount_point"
    
    # Copy NimbOS binary
    sudo cp "$nimbos_binary" "$mount_point/${NIMBOS_IMAGE_NAME}.bin"
    
    # Copy BIOS for x86_64
    if [ "${NIMBOS_PLATFORM}" == "x86_64" ] && [ -f "$AXVM_BIOS_X86_SRC_DIR/out/axvm-bios.bin" ]; then
        info "Copying AXVM BIOS to disk image..."
        sudo cp "$AXVM_BIOS_X86_SRC_DIR/out/axvm-bios.bin" "$mount_point/axvm-bios.bin"
    fi
    
    # Set proper permissions
    sudo chown -R root:root "$mount_point"
    sudo chmod 755 "$mount_point"
    sudo chmod 644 "$mount_point"/*
    
    # Unmount
    sudo umount "$mount_point"
    
    # Cleanup mount point
    sudo rm -rf "$mount_point"
    
    success "NimbOS disk image created: $disk_image_path (${disk_size_mb}MB)"
}

nimbos() {
    if [[ "${NIMBOS_ARGS}" != *"clean"* ]]; then
        info "Cloning NimbOS source repository $NIMBOS_REPO_URL -> $NIMBOS_SRC_DIR"
        clone_repository "$NIMBOS_REPO_URL" "$NIMBOS_SRC_DIR"
        info "Checking out NimbOS ref ${NIMBOS_REF}"
        checkout_ref "$NIMBOS_SRC_DIR" "$NIMBOS_REF"
    fi

    info "Starting to build NimbOS system..."
    build_nimbos
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            nimbos_usage
            exit 0
            ;;
        aarch64)
            NIMBOS_PLATFORM="aarch64"
            ;;
        riscv64)
            NIMBOS_PLATFORM="riscv64"
            ;;
        x86_64)
            NIMBOS_PLATFORM="x86_64"
            ;;
        all)
            for platform in aarch64 riscv64 x86_64; do
                "$0" "$platform" "$@" || { echo "[ERROR] $platform build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        clean)
            for platform in aarch64 riscv64 x86_64; do
                "$0" "$platform" "clean" || { echo "[ERROR] $platform build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac

    # Parse the other arguments
    nimbos_parse_args "$@"

    if [[ -z "${NIMBOS_IMAGE_NAME}" ]]; then
        NIMBOS_IMAGE_NAME="${NIMBOS_PLATFORM}"
    fi

    # Call the main function
    nimbos
fi
