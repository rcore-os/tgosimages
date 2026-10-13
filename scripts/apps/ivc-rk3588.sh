#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
TGOSIMAGES_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${TGOSIMAGES_ROOT}/scripts/lib/build-paths.sh"
build_paths_init "$TGOSIMAGES_ROOT"

source "${TGOSIMAGES_ROOT}/scripts/lib/utils.sh"

IVC_SDK_REPO_URL="${IVC_SDK_REPO_URL:-https://github.com/rcore-os/ivc-sdk.git}"
IVC_SDK_REF="${IVC_SDK_REF:-}"
IVC_SDK_DIR="${IVC_SDK_DIR:-}"
TGOSKITS_REPO_URL="${TGOSKITS_REPO_URL:-https://github.com/rcore-os/tgoskits.git}"
TGOSKITS_REF="${TGOSKITS_REF:-dev}"
TGOSKITS_SRC_DIR="${TGOSKITS_SRC_DIR:-${BUILD_DIR}/tgoskits-starry}"

OUTPUT_ROOT="${OUTPUT_ROOT:-${TGOSIMAGES_ROOT}/IMAGES/orangepi/ivc}"
ZEPHYR_IMAGES_DIR="${ZEPHYR_IMAGES_DIR:-${TGOSIMAGES_ROOT}/IMAGES/orangepi/zephyr}"
ZEPHYR_SHELL_APP="${ZEPHYR_SHELL_APP:-${TGOSIMAGES_ROOT}/apps/zephyr/orangepi-shell}"
ZEPHYR_SHELL_IMAGE_NAME="${ZEPHYR_SHELL_IMAGE_NAME:-orangepi-5-plus}"
AKA_RK3588_SOURCE_DIR="${AKA_RK3588_SOURCE_DIR:-}"
AKA_RK3588_LIBRARY="${AKA_RK3588_LIBRARY:-}"
AKA_RK3588_INCLUDE_DIR="${AKA_RK3588_INCLUDE_DIR:-}"
STAGE_DIR="${STAGE_DIR:-${OUTPUT_ROOT}}"
IVC_BUILD_DIR="${IVC_BUILD_DIR:-${BUILD_DIR}/ivc-sdk}"

STARRY_CONFIG="${STARRY_CONFIG:-os/StarryOS/configs/board/orangepi-5-plus.toml}"
STARRY_IMAGES_DIR="${STARRY_IMAGES_DIR:-${TGOSIMAGES_ROOT}/IMAGES/orangepi/starry}"
STARRY_RELEASE_IMAGES_DIR="${STARRY_RELEASE_IMAGES_DIR:-${TGOSIMAGES_ROOT}/IMAGES/orangepi/starry}"
STARRY_IMAGE_NAME="${STARRY_IMAGE_NAME:-orangepi-5-plus}"
STARRY_LOG="${STARRY_LOG:-Error}"

AXIVC_BENCH_ITERATIONS="${AXIVC_BENCH_ITERATIONS:-}"
SKIP_STARRY_IMAGE=0
SKIP_ZEPHYR=0
SKIP_USER_APPS=0
SHELL_ONLY=0

usage() {
    cat <<'EOF'
Build Orange Pi 5 Plus AXIVC Starry/Zephyr payloads.

Usage:
  scripts/apps/ivc-rk3588.sh [options]

Options:
  --ivc-sdk-dir <path>       Use this ivc-sdk checkout
  --ivc-sdk-repo-url <url>   Repository used only when ivc-sdk is absent
  --ivc-sdk-ref <ref>        Version for managed ivc-sdk checkout
  --tgoskits-repo-url <url>  tgoskits repository or local path for StarryOS
  --tgoskits-ref <ref>       tgoskits ref for StarryOS build (default: dev)
  --tgoskits-src-dir <path>  StarryOS source/build checkout directory
  --output-root <path>       Output root (default: IMAGES/orangepi/ivc)
  --stage-dir <path>         Payload directory (default: <output-root>)
  --ivc-build-dir <path>     ivc-sdk object output directory
  --zephyr-shell-app <path>  Unified Zephyr Shell application
  --aka-dir <path>           AKA checkout to compile into the unified shell
  --aka-library <path>       Optional aka-rk3588 library to link into shell
  --aka-include-dir <path>   Optional aka-rk3588 include directory
  --starry-config <path>     StarryOS build config relative to tgoskits
  --starry-log <level>       StarryOS log level override (default: Error)
  --bench-iterations <n>     Define AXIVC_BENCH_ITERATIONS for benchmark builds
  --skip-starry-image        Do not rebuild the StarryOS kernel image
  --skip-zephyr              Do not rebuild Zephyr images
  --skip-user-apps           Do not rebuild Starry userspace programs
  --shell-only               Build only the unified Orange Pi Zephyr shell
  -h, --help                 Show this help

Outputs:
  <stage-dir>/usr/bin/ivc-roundtrip
  <stage-dir>/usr/bin/ivc-demo
  <stage-dir>/usr/bin/ivc-starry-bench
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ivc-sdk-dir)
            [[ $# -ge 2 ]] || die "--ivc-sdk-dir needs a path"
            IVC_SDK_DIR="$2"
            shift 2
            ;;
        --ivc-sdk-repo-url)
            [[ $# -ge 2 ]] || die "--ivc-sdk-repo-url needs a URL"
            IVC_SDK_REPO_URL="$2"
            shift 2
            ;;
        --ivc-sdk-ref)
            [[ $# -ge 2 ]] || die "--ivc-sdk-ref needs a ref"
            IVC_SDK_REF="$2"
            shift 2
            ;;
        --tgoskits-repo-url)
            [[ $# -ge 2 ]] || die "--tgoskits-repo-url needs a URL or path"
            TGOSKITS_REPO_URL="$2"
            shift 2
            ;;
        --tgoskits-ref)
            [[ $# -ge 2 ]] || die "--tgoskits-ref needs a ref"
            TGOSKITS_REF="$2"
            shift 2
            ;;
        --tgoskits-src-dir)
            [[ $# -ge 2 ]] || die "--tgoskits-src-dir needs a path"
            TGOSKITS_SRC_DIR="$2"
            shift 2
            ;;
        --output-root)
            [[ $# -ge 2 ]] || die "--output-root needs a path"
            OUTPUT_ROOT="$2"
            STAGE_DIR="${OUTPUT_ROOT}"
            shift 2
            ;;
        --stage-dir)
            [[ $# -ge 2 ]] || die "--stage-dir needs a path"
            STAGE_DIR="$2"
            shift 2
            ;;
        --ivc-build-dir)
            [[ $# -ge 2 ]] || die "--ivc-build-dir needs a path"
            IVC_BUILD_DIR="$2"
            shift 2
            ;;
        --zephyr-shell-app)
            [[ $# -ge 2 ]] || die "--zephyr-shell-app needs a path"
            ZEPHYR_SHELL_APP="$2"
            shift 2
            ;;
        --aka-dir)
            [[ $# -ge 2 ]] || die "--aka-dir needs a path"
            AKA_RK3588_SOURCE_DIR="$2"
            shift 2
            ;;
        --aka-library)
            [[ $# -ge 2 ]] || die "--aka-library needs a path"
            AKA_RK3588_LIBRARY="$2"
            shift 2
            ;;
        --aka-include-dir)
            [[ $# -ge 2 ]] || die "--aka-include-dir needs a path"
            AKA_RK3588_INCLUDE_DIR="$2"
            shift 2
            ;;
        --starry-config)
            [[ $# -ge 2 ]] || die "--starry-config needs a path"
            STARRY_CONFIG="$2"
            shift 2
            ;;
        --starry-log)
            [[ $# -ge 2 ]] || die "--starry-log needs a level"
            STARRY_LOG="$2"
            shift 2
            ;;
        --bench-iterations)
            [[ $# -ge 2 ]] || die "--bench-iterations needs a value"
            AXIVC_BENCH_ITERATIONS="$2"
            shift 2
            ;;
        --skip-starry-image)
            SKIP_STARRY_IMAGE=1
            shift
            ;;
        --skip-zephyr)
            SKIP_ZEPHYR=1
            shift
            ;;
        --skip-user-apps)
            SKIP_USER_APPS=1
            shift
            ;;
        --shell-only)
            SHELL_ONLY=1
            SKIP_STARRY_IMAGE=1
            SKIP_USER_APPS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# SDK make runs from its own checkout; normalize caller-relative object paths.
IVC_BUILD_DIR=$(realpath -m -- "$IVC_BUILD_DIR")

resolve_ivc_sdk() {
    local provided=0
    [[ -z $IVC_SDK_DIR ]] || provided=1
    IVC_SDK_DIR="${IVC_SDK_DIR:-${BUILD_DIR}/ivc-sdk-source}"
    build_prepare_checkout "$IVC_SDK_DIR" "$IVC_SDK_REPO_URL" "${IVC_SDK_REF:-HEAD}" "$provided"
    IVC_SDK_DIR=$(cd "$IVC_SDK_DIR" && pwd -P)

    [[ -f "${IVC_SDK_DIR}/Makefile" ]] || die "ivc-sdk Makefile not found: ${IVC_SDK_DIR}/Makefile"
    [[ -f "${IVC_SDK_DIR}/zephyr/module.yml" ]] || die "ivc-sdk Zephyr module not found: ${IVC_SDK_DIR}/zephyr/module.yml"
}

print_build_inputs() {
    info "TGOSIMAGES_DIR=${TGOSIMAGES_ROOT}"
    info "IVC_SDK_DIR=${IVC_SDK_DIR}"
    info "IVC_SDK_COMMIT=$(git -C "${IVC_SDK_DIR}" rev-parse --short HEAD)"
    if [[ -n "$(git -C "${IVC_SDK_DIR}" status --short)" ]]; then
        warn "IVC_SDK_WORKTREE=dirty (building local files without changing them)"
    else
        info "IVC_SDK_WORKTREE=clean"
    fi
    info "TGOSKITS_REPO_URL=${TGOSKITS_REPO_URL}"
    info "TGOSKITS_REF=${TGOSKITS_REF}"
    info "OUTPUT_ROOT=${OUTPUT_ROOT}"
}

build_user_apps() {
    [[ "${SKIP_USER_APPS}" == "0" ]] || return 0

    ensure_musl_toolchain aarch64
    info "Building Starry userspace AXIVC programs from ivc-sdk"
    build_make -C "${IVC_SDK_DIR}" clean-linux BUILD_DIR="${IVC_BUILD_DIR}"
    build_make -C "${IVC_SDK_DIR}" all BUILD_DIR="${IVC_BUILD_DIR}"
    source "${TGOSIMAGES_ROOT}/scripts/lib/ivc-user-apps.sh"
    build_ivc_roundtrip "${TGOSIMAGES_ROOT}" "${IVC_SDK_DIR}" "${IVC_BUILD_DIR}"
}

build_zephyr_images() {
    [[ "${SKIP_ZEPHYR}" == "0" ]] || return 0

    [[ -f "${ZEPHYR_SHELL_APP}/CMakeLists.txt" ]] ||
        die "Unified Zephyr Shell app not found: ${ZEPHYR_SHELL_APP}"
    info "Building unified Orange Pi Zephyr Shell"
    if [[ -n "${AKA_RK3588_SOURCE_DIR}" ]]; then
        [[ -f "${AKA_RK3588_SOURCE_DIR}/zephyr/orangepi_robot_control/CMakeLists.txt" ]] ||
            die "AKA controller source not found: ${AKA_RK3588_SOURCE_DIR}"
        AKA_RK3588_SOURCE_DIR=$(cd "${AKA_RK3588_SOURCE_DIR}" && pwd -P)
    fi
    if [[ -n "${AKA_RK3588_LIBRARY}" ]]; then
        [[ -f "${AKA_RK3588_LIBRARY}" ]] || die "AKA library not found: ${AKA_RK3588_LIBRARY}"
    fi
    if [[ -n "${AKA_RK3588_INCLUDE_DIR}" ]]; then
        [[ -d "${AKA_RK3588_INCLUDE_DIR}" ]] || die "AKA include directory not found: ${AKA_RK3588_INCLUDE_DIR}"
    fi
    local -a aka_args=(
        "-DAKA_RK3588_SOURCE_DIR=${AKA_RK3588_SOURCE_DIR}"
        "-DAKA_RK3588_LIBRARY=${AKA_RK3588_LIBRARY}"
        "-DAKA_RK3588_INCLUDE_DIR=${AKA_RK3588_INCLUDE_DIR}"
    )
    AXIVC_BENCH_ITERATIONS="${AXIVC_BENCH_ITERATIONS}" \
        "${TGOSIMAGES_ROOT}/scripts/os/zephyr.sh" orangepi-5-plus \
            --images-dir "${ZEPHYR_IMAGES_DIR}" \
            --image-name "${ZEPHYR_SHELL_IMAGE_NAME}" \
            --app "${ZEPHYR_SHELL_APP}" \
            --extra-module "${IVC_SDK_DIR}" \
            "${aka_args[@]}"
}

build_starry_image() {
    [[ "${SKIP_STARRY_IMAGE}" == "0" ]] || return 0

    info "Building StarryOS kernel image via tgosimages Starry script"
    "${TGOSIMAGES_ROOT}/scripts/os/starry.sh" orangepi-5-plus \
        --repo-url "${TGOSKITS_REPO_URL}" \
        --ref "${TGOSKITS_REF}" \
        --src-dir "${TGOSKITS_SRC_DIR}" \
        --config "${STARRY_CONFIG}" \
        --log "${STARRY_LOG}" \
        --images-dir "${STARRY_IMAGES_DIR}" \
        --release-images-dir "${STARRY_RELEASE_IMAGES_DIR}" \
        --image-name "${STARRY_IMAGE_NAME}"
}

stage_payloads() {
    info "Staging AXIVC payloads into ${STAGE_DIR}"
    local required_artifacts=(
        "${IVC_BUILD_DIR}/examples/ivc-roundtrip"
        "${IVC_BUILD_DIR}/examples/ivc-demo"
        "${IVC_BUILD_DIR}/examples/ivc-starry-bench"
    )
    local artifact

    for artifact in "${required_artifacts[@]}"; do
        [[ -e "${artifact}" ]] || die "Required artifact not found: ${artifact}"
    done

    rm -rf "${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}/usr/bin" "${STAGE_DIR}/usr/lib"

    copy_required "${IVC_BUILD_DIR}/examples/ivc-demo" "${STAGE_DIR}/usr/bin/ivc-demo"
    copy_required "${IVC_BUILD_DIR}/examples/ivc-starry-bench" "${STAGE_DIR}/usr/bin/ivc-starry-bench"
    copy_required "${IVC_BUILD_DIR}/examples/ivc-roundtrip" "${STAGE_DIR}/usr/bin/ivc-roundtrip"
    copy_optional "${IVC_BUILD_DIR}/libaxivc.so" "${STAGE_DIR}/usr/lib/libaxivc.so"

    chmod 0755 "${STAGE_DIR}/usr/bin/ivc-roundtrip" "${STAGE_DIR}/usr/bin/ivc-demo" "${STAGE_DIR}/usr/bin/ivc-starry-bench"
    success "AXIVC RK3588 payloads are ready in ${STAGE_DIR}"
}

if [[ "${SHELL_ONLY}" == "1" ]]; then
    resolve_ivc_sdk
    build_zephyr_images
    exit 0
fi

resolve_ivc_sdk
print_build_inputs
build_user_apps
build_zephyr_images
build_starry_image
stage_payloads
