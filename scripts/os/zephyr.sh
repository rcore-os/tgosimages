#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

ZEPHYR_REPO_URL="${ZEPHYR_REPO_URL:-https://github.com/zephyrproject-rtos/zephyr.git}"
ZEPHYR_REF="${ZEPHYR_REF:-30bef2a126198f73ecc1f8a90590579e03379b18}"
ZEPHYR_SRC_DIR="${ZEPHYR_SRC_DIR:-${BUILD_DIR}/zephyr}"
ZEPHYR_PATCH_DIR="${ZEPHYR_PATCH_DIR:-${ROOT_DIR}/patches/zephyr}"
ZEPHYR_PYENV="${ZEPHYR_PYENV:-/tmp/zephyr-pyenv}"
ZEPHYR_PYTHON="${ZEPHYR_PYTHON:-${ZEPHYR_PYENV}/bin/python}"
ZEPHYR_SDK_URL="${ZEPHYR_SDK_URL:-https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.1/toolchain_gnu_linux-x86_64_aarch64-zephyr-elf.tar.xz}"
ZEPHYR_SDK_DIR="${ZEPHYR_SDK_DIR:-${BUILD_DIR}/zephyr-sdk}"
ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-cross-compile}"
ZEPHYR_CROSS_COMPILE="${ZEPHYR_CROSS_COMPILE:-${ZEPHYR_SDK_DIR}/bin/aarch64-zephyr-elf-}"

ZEPHYR_PLATFORM=""
ZEPHYR_APP=""
ZEPHYR_BOARD=""
ZEPHYR_BOARD_ROOT=""
ZEPHYR_BUILD_SUBDIR=""
ZEPHYR_IMAGES_DIR=""
ZEPHYR_IMAGE_NAME=""
ZEPHYR_BIN_NAME=""
ZEPHYR_ELF_NAME=""
ZEPHYR_DTB_NAME=""
ZEPHYR_ARGS=()

zephyr_usage() {
    printf 'Zephyr build script for AxVisor guest images\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/zephyr.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  qemu-aarch64                  Build Zephyr guest for QEMU aarch64\n'
    printf '  phytiumpi                     Build Zephyr guest for PhytiumPi\n'
    printf '  tac-e400-plc                  Build Zephyr guest for TAC-E400-PLC\n'
    printf '  orangepi-5-plus               Build Zephyr guest for Orange Pi 5 Plus\n'
    printf '  all                           Build all supported Zephyr guest images\n'
    printf '  clean                         Clean all supported Zephyr guest images\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf 'Options:\n'
    printf '  --repo-url <url>              Zephyr repository URL or local path\n'
    printf '  --ref <ref>                   Optional git ref to checkout before applying patches\n'
    printf '  --src-dir <dir>               Zephyr source directory\n'
    printf '  --patch-dir <dir>             Patch directory (empty to disable)\n'
    printf '  --python <path>               Python executable for Zephyr build helpers\n'
    printf '  --cross-compile <prefix>      CROSS_COMPILE prefix\n'
    printf '  --images-dir <dir>            Output image directory override\n'
    printf '  --image-name <name>           Output image base name (default: current command)\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/zephyr.sh qemu-aarch64\n'
    printf '  scripts/zephyr.sh phytiumpi --repo-url /code/rtos/zephyr --ref 4e5cb31d32a\n'
}

zephyr_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url)
                ZEPHYR_REPO_URL="$2"
                shift 2
                ;;
            --ref)
                ZEPHYR_REF="$2"
                shift 2
                ;;
            --src-dir)
                ZEPHYR_SRC_DIR="$2"
                shift 2
                ;;
            --patch-dir)
                ZEPHYR_PATCH_DIR="$2"
                shift 2
                ;;
            --python)
                ZEPHYR_PYTHON="$2"
                shift 2
                ;;
            --cross-compile)
                ZEPHYR_CROSS_COMPILE="$2"
                shift 2
                ;;
            --images-dir)
                ZEPHYR_IMAGES_DIR="$2"
                shift 2
                ;;
            --image-name)
                ZEPHYR_IMAGE_NAME="$2"
                shift 2
                ;;
            *)
                ZEPHYR_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

ensure_zephyr_python() {
    if [[ ! -x "${ZEPHYR_PYTHON}" ]]; then
        info "Creating Zephyr Python venv at ${ZEPHYR_PYENV}"
        python3 -m venv "${ZEPHYR_PYENV}"
    fi

    if ! "${ZEPHYR_PYTHON}" -c 'import pykwalify, yaml, west' >/dev/null 2>&1; then
        info "Installing Zephyr Python requirements"
        "${ZEPHYR_PYENV}/bin/pip" install -r "${ZEPHYR_SRC_DIR}/scripts/requirements-base.txt"
    fi
}

ensure_zephyr_sdk() {
    if [[ -x "${ZEPHYR_CROSS_COMPILE}gcc" ]]; then
        info "Zephyr SDK toolchain found at ${ZEPHYR_SDK_DIR}"
        return 0
    fi

    info "Downloading Zephyr SDK from ${ZEPHYR_SDK_URL}"
    local tmpdir
    tmpdir=$(mktemp -d)
    local archive="${tmpdir}/zephyr-sdk.tar.xz"

    curl -fSL -o "${archive}" "${ZEPHYR_SDK_URL}"

    info "Extracting Zephyr SDK to ${ZEPHYR_SDK_DIR}"
    mkdir -p "${ZEPHYR_SDK_DIR}"
    tar xf "${archive}" -C "${ZEPHYR_SDK_DIR}" --strip-components=1

    rm -rf "${tmpdir}"

    if [[ ! -x "${ZEPHYR_CROSS_COMPILE}gcc" ]]; then
        die "Zephyr SDK toolchain not found after extraction: ${ZEPHYR_CROSS_COMPILE}gcc"
    fi
    info "Zephyr SDK installed at ${ZEPHYR_SDK_DIR}"
}

prepare_zephyr_source() {
    if [[ ! -d "${ZEPHYR_SRC_DIR}/.git" ]]; then
        info "Cloning Zephyr source repository ${ZEPHYR_REPO_URL} -> ${ZEPHYR_SRC_DIR}"
        clone_repository "${ZEPHYR_REPO_URL}" "${ZEPHYR_SRC_DIR}"
    else
        info "Using existing Zephyr source tree at ${ZEPHYR_SRC_DIR}"
    fi

    if [[ -d "${ZEPHYR_SRC_DIR}/.patch_stamps" ]] && find "${ZEPHYR_SRC_DIR}/.patch_stamps" -type f | read -r; then
        info "Detected previously applied Zephyr patches, reusing current source state"
    else
        if [[ -n "${ZEPHYR_REF}" ]]; then
            info "Checking out Zephyr ref ${ZEPHYR_REF}"
            checkout_ref "${ZEPHYR_SRC_DIR}" "${ZEPHYR_REF}"
        fi

        if [[ -n "${ZEPHYR_PATCH_DIR}" && -d "${ZEPHYR_PATCH_DIR}" ]]; then
            info "Applying Zephyr patches from ${ZEPHYR_PATCH_DIR}"
            apply_patches "${ZEPHYR_PATCH_DIR}" "${ZEPHYR_SRC_DIR}"
        fi
    fi
}

copy_if_exists() {
    local src="$1"
    local dst="$2"
    if [[ -f "${src}" ]]; then
        cp -f "${src}" "${dst}"
    fi
}

prepare_module_metadata() {
    local build_dir="$1"

    mkdir -p "${build_dir}/Kconfig"

    "${ZEPHYR_PYTHON}" "${ZEPHYR_SRC_DIR}/scripts/zephyr_module.py" \
        --kconfig-out "${build_dir}/Kconfig/Kconfig.modules" \
        --sysbuild-kconfig-out "${build_dir}/Kconfig/Kconfig.sysbuild.modules" \
        --cmake-out "${build_dir}/zephyr_modules.txt" \
        --settings-out "${build_dir}/zephyr_settings.txt" \
        -z "${ZEPHYR_SRC_DIR}"
}

zephyr_build() {
    local build_dir="${BUILD_DIR}/${ZEPHYR_BUILD_SUBDIR}"
    local source_dir="${ZEPHYR_SRC_DIR}/${ZEPHYR_APP}"

    if [[ "${ZEPHYR_ARGS[*]:-}" == *"clean"* ]]; then
        info "Cleaning Zephyr build directory ${build_dir}"
        rm -rf "${build_dir}" "${ZEPHYR_IMAGES_DIR}"
        return 0
    fi

    prepare_zephyr_source
    ensure_zephyr_sdk
    ensure_zephyr_python

    if [[ ! -d "${ZEPHYR_SRC_DIR}/.west" ]]; then
        info "Initializing west workspace in ${ZEPHYR_SRC_DIR}"
        "${ZEPHYR_PYENV}/bin/west" init -l "${ZEPHYR_SRC_DIR}" --mf west.yml
    fi

    if [[ -f "${build_dir}/CMakeCache.txt" ]]; then
        local cached_home
        cached_home=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "${build_dir}/CMakeCache.txt" | tail -n 1)
        if [[ -n "${cached_home}" && "${cached_home}" != "${source_dir}" ]]; then
            info "Resetting Zephyr build directory because source changed: ${cached_home} -> ${source_dir}"
            rm -rf "${build_dir}"
        fi
    fi

    prepare_module_metadata "${build_dir}"

    mkdir -p "${ZEPHYR_IMAGES_DIR}"

    info "Building Zephyr app ${ZEPHYR_APP} for board ${ZEPHYR_BOARD}"
    export ZEPHYR_BASE="${ZEPHYR_SRC_DIR}"
    export CROSS_COMPILE="${ZEPHYR_CROSS_COMPILE}"
    export CCACHE_DISABLE=1

    local cmake_args=(
        -GNinja
        -B "${build_dir}"
        -S "${source_dir}"
        -DBOARD="${ZEPHYR_BOARD}"
        -DZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT}"
        -DPython3_EXECUTABLE="${ZEPHYR_PYTHON}"
    )

    if [[ -n "${ZEPHYR_BOARD_ROOT}" ]]; then
        cmake_args+=("-DBOARD_ROOT=${ZEPHYR_BOARD_ROOT}")
    fi

    if (( ${#ZEPHYR_ARGS[@]} > 0 )); then
        cmake_args+=("${ZEPHYR_ARGS[@]}")
    fi

    info "Configuring Zephyr build in ${build_dir}"
    cmake "${cmake_args[@]}"

    info "Compiling Zephyr image"
    cmake --build "${build_dir}" -j"$(nproc)"

    copy_if_exists "${build_dir}/zephyr/zephyr.bin" "${ZEPHYR_IMAGES_DIR}/${ZEPHYR_BIN_NAME}"
    if [[ -n "${ZEPHYR_ELF_NAME}" ]]; then
        copy_if_exists "${build_dir}/zephyr/zephyr.elf" "${ZEPHYR_IMAGES_DIR}/${ZEPHYR_ELF_NAME}"
    fi
    if [[ -n "${ZEPHYR_DTB_NAME}" ]]; then
        if [[ -f "${build_dir}/zephyr/zephyr.dtb" ]]; then
            copy_if_exists "${build_dir}/zephyr/zephyr.dtb" "${ZEPHYR_IMAGES_DIR}/${ZEPHYR_DTB_NAME}"
        elif [[ -f "${build_dir}/zephyr/zephyr.dts" ]]; then
            dtc -I dts -O dtb -o "${ZEPHYR_IMAGES_DIR}/${ZEPHYR_DTB_NAME}" "${build_dir}/zephyr/zephyr.dts"
        fi
    fi

    success "Zephyr build artifacts collected in ${ZEPHYR_IMAGES_DIR}"
}

configure_platform() {
    if [[ -z "${ZEPHYR_IMAGE_NAME}" ]]; then
        ZEPHYR_IMAGE_NAME="${ZEPHYR_PLATFORM}"
    fi

    case "${ZEPHYR_PLATFORM}" in
        qemu-aarch64)
            ZEPHYR_APP="tests/benchmarks/latency_measure"
            ZEPHYR_BOARD="qemu_cortex_a53"
            ZEPHYR_BUILD_SUBDIR="zephyr/qemu-aarch64"
            : "${ZEPHYR_IMAGES_DIR:=${ROOT_DIR}/IMAGES/qemu-aarch64/zephyr}"
            ;;
        phytiumpi)
            ZEPHYR_APP="tests/benchmarks/latency_measure"
            ZEPHYR_BOARD="phytiumpi_axvisor_guest"
            ZEPHYR_BUILD_SUBDIR="zephyr/phytiumpi"
            : "${ZEPHYR_IMAGES_DIR:=${ROOT_DIR}/IMAGES/phytiumpi/zephyr}"
            ;;
        tac-e400-plc)
            ZEPHYR_APP="tests/benchmarks/latency_measure"
            ZEPHYR_BOARD="phytiumpi_axvisor_guest"
            ZEPHYR_BUILD_SUBDIR="zephyr/tac-e400-plc"
            : "${ZEPHYR_IMAGES_DIR:=${ROOT_DIR}/IMAGES/tac-e400-plc/zephyr}"
            ;;
        orangepi-5-plus)
            ZEPHYR_APP="tests/benchmarks/latency_measure"
            ZEPHYR_BOARD="orangepi_5_plus_rk3588"
            ZEPHYR_BUILD_SUBDIR="zephyr/orangepi-5-plus"
            : "${ZEPHYR_IMAGES_DIR:=${ROOT_DIR}/IMAGES/orangepi/zephyr}"
            ;;
        *)
            die "Unknown Zephyr platform: ${ZEPHYR_PLATFORM}"
            ;;
    esac

    ZEPHYR_BIN_NAME="${ZEPHYR_IMAGE_NAME}"
    ZEPHYR_ELF_NAME="${ZEPHYR_IMAGE_NAME}.elf"
    if [[ "${ZEPHYR_PLATFORM}" != "qemu-aarch64" ]]; then
        ZEPHYR_DTB_NAME="${ZEPHYR_IMAGE_NAME}.dtb"
    else
        ZEPHYR_DTB_NAME=""
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "${cmd}" in
        ""|help|-h|--help)
            zephyr_usage
            exit 0
            ;;
        qemu-aarch64|phytiumpi|tac-e400-plc|orangepi-5-plus)
            ZEPHYR_PLATFORM="${cmd}"
            ;;
        all)
            for platform in qemu-aarch64 phytiumpi tac-e400-plc orangepi-5-plus; do
                "$0" "${platform}" "$@" || { echo "[ERROR] ${platform} build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        clean)
            for platform in qemu-aarch64 phytiumpi tac-e400-plc orangepi-5-plus; do
                "$0" "${platform}" clean || { echo "[ERROR] ${platform} clean failed" >&2; exit 1; }
            done
            exit 0
            ;;
        *)
            die "Unknown command: ${cmd}"
            ;;
    esac

    zephyr_parse_args "$@"
    configure_platform
    zephyr_build
fi
