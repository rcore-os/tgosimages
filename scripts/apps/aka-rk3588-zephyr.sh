#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
TGOSIMAGES_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${TGOSIMAGES_ROOT}/scripts/lib/build-paths.sh"
build_paths_init "$TGOSIMAGES_ROOT"
source "${TGOSIMAGES_ROOT}/scripts/lib/log.sh"
AKA_REPO_URL="${AKA_RK3588_REPO_URL:-https://github.com/bullhh/aka-rk3588.git}"
AKA_REF="${AKA_RK3588_REF:-dual}"
AKA_DIR="${AKA_RK3588_DIR:-}"
IVC_SDK_REPO_URL="${IVC_SDK_REPO_URL:-https://github.com/rcore-os/ivc-sdk.git}"
IVC_SDK_REF="${IVC_SDK_REF:-}"
IVC_SDK_DIR="${IVC_SDK_DIR:-}"
FORWARD_ARGS=()
usage() {
    cat <<'EOF'
Build the aka-rk3588 Zephyr controller with this TGOSImages checkout.

Usage:
  scripts/apps/aka-rk3588-zephyr.sh [options] [Zephyr options]

Options:
  --aka-dir <path>       Use this aka-rk3588 checkout
  --aka-repo-url <url>   Repository used only when aka-rk3588 is absent
  --aka-ref <ref>        Version for managed checkout (default: dual)
  --ivc-sdk-dir <path>   Use this ivc-sdk checkout
  --ivc-sdk-ref <ref>    Version for managed ivc-sdk checkout
  -h, --help             Show this help

Resolution order:
  1. --aka-dir
  2. AKA_RK3588_DIR
  3. ${BUILD_WORK_DIR:-<repo>/build}/aka-rk3588
  4. clone the repository's dual branch into that build directory

ivc-sdk accepts --ivc-sdk-dir or IVC_SDK_DIR and defaults to <build>/ivc-sdk-source.

Explicit checkouts are used as-is. Managed build checkouts are updated and cleaned on rerun.
Unrecognized options are passed to scripts/os/zephyr.sh.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --aka-dir)
            [[ $# -ge 2 ]] || { error "--aka-dir needs a path"; exit 2; }
            AKA_DIR="$2"
            shift 2
            ;;
        --aka-repo-url)
            [[ $# -ge 2 ]] || { error "--aka-repo-url needs a URL"; exit 2; }
            AKA_REPO_URL="$2"
            shift 2
            ;;
        --aka-ref)
            [[ $# -ge 2 ]] || { error "--aka-ref needs a ref"; exit 2; }
            AKA_REF="$2"
            shift 2
            ;;
        --ivc-sdk-dir)
            [[ $# -ge 2 ]] || { error "--ivc-sdk-dir needs a path"; exit 2; }
            IVC_SDK_DIR="$2"
            shift 2
            ;;
        --ivc-sdk-ref)
            [[ $# -ge 2 ]] || { error "--ivc-sdk-ref needs a ref"; exit 2; }
            IVC_SDK_REF="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            FORWARD_ARGS+=("$1")
            shift
            ;;
    esac
done

AKA_SOURCE_PROVIDED=0
[[ -z $AKA_DIR ]] || AKA_SOURCE_PROVIDED=1
AKA_DIR="${AKA_DIR:-${BUILD_DIR}/aka-rk3588}"
build_prepare_checkout "$AKA_DIR" "$AKA_REPO_URL" "$AKA_REF" "$AKA_SOURCE_PROVIDED"
AKA_DIR=$(cd "$AKA_DIR" && pwd -P)

APP_DIR="${AKA_DIR}/zephyr/orangepi_robot_control"
if [[ ! -f "${APP_DIR}/CMakeLists.txt" ]]; then
    error "Zephyr robot application not found: ${APP_DIR}"
    exit 1
fi

IVC_SOURCE_PROVIDED=0
[[ -z $IVC_SDK_DIR ]] || IVC_SOURCE_PROVIDED=1
IVC_SDK_DIR="${IVC_SDK_DIR:-${BUILD_DIR}/ivc-sdk-source}"
build_prepare_checkout "$IVC_SDK_DIR" "$IVC_SDK_REPO_URL" "${IVC_SDK_REF:-HEAD}" "$IVC_SOURCE_PROVIDED"
IVC_SDK_DIR=$(cd "$IVC_SDK_DIR" && pwd -P)
if [[ ! -f "${IVC_SDK_DIR}/zephyr/module.yml" ]]; then
    error "Zephyr ivc-sdk module not found: ${IVC_SDK_DIR}/zephyr/module.yml"
    exit 1
fi

info "TGOSIMAGES_DIR=${TGOSIMAGES_ROOT}"
info "AKA_RK3588_DIR=${AKA_DIR}"
info "AKA_RK3588_COMMIT=$(git -C "${AKA_DIR}" rev-parse --short HEAD)"
info "IVC_SDK_DIR=${IVC_SDK_DIR}"
info "IVC_SDK_COMMIT=$(git -C "${IVC_SDK_DIR}" rev-parse --short HEAD)"
if [[ -n "$(git -C "${AKA_DIR}" status --short)" ]]; then
    info "AKA_RK3588_WORKTREE=dirty (building local files without changing them)"
else
    info "AKA_RK3588_WORKTREE=clean"
fi

if [[ -n "$(git -C "${IVC_SDK_DIR}" status --short)" ]]; then
    info "IVC_SDK_WORKTREE=dirty (building local files without changing them)"
else
    info "IVC_SDK_WORKTREE=clean"
fi

exec "${TGOSIMAGES_ROOT}/scripts/os/zephyr.sh" orangepi-5-plus \
    --app "${APP_DIR}" --extra-module "${IVC_SDK_DIR}" \
    "${FORWARD_ARGS[@]}"
