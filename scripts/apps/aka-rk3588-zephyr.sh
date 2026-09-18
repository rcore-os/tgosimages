#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
TGOSIMAGES_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${TGOSIMAGES_ROOT}/scripts/lib/log.sh"
AKA_REPO_URL="${AKA_RK3588_REPO_URL:-https://github.com/bullhh/aka-rk3588.git}"
AKA_REF="${AKA_RK3588_REF:-}"
AKA_DIR="${AKA_RK3588_DIR:-}"
IVC_SDK_REPO_URL="${IVC_SDK_REPO_URL:-https://github.com/rcore-os/ivc-sdk.git}"
IVC_SDK_REF="${IVC_SDK_REF:-}"
IVC_SDK_DIR="${IVC_SDK_DIR:-}"
FORWARD_ARGS=()
CLONED=0
IVC_SDK_CLONED=0

usage() {
    cat <<'EOF'
Build the aka-rk3588 Zephyr controller with this TGOSImages checkout.

Usage:
  scripts/apps/aka-rk3588-zephyr.sh [options] [Zephyr options]

Options:
  --aka-dir <path>       Use this aka-rk3588 checkout
  --aka-repo-url <url>   Repository used only when aka-rk3588 is absent
  --aka-ref <ref>        Checkout this ref only after a fresh clone
  --ivc-sdk-dir <path>   Use this ivc-sdk checkout
  --ivc-sdk-ref <ref>    Checkout this ref only after a fresh ivc-sdk clone
  -h, --help             Show this help

Resolution order:
  1. --aka-dir
  2. AKA_RK3588_DIR
  3. sibling directory ../aka-rk3588
  4. clone the repository's current default branch into ../aka-rk3588

ivc-sdk uses the same resolution order and defaults to ../ivc-sdk.

An existing aka-rk3588 checkout is never pulled, switched, or cleaned.
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

if [[ -z "${AKA_DIR}" ]]; then
    AKA_DIR="${TGOSIMAGES_ROOT}/../aka-rk3588"
fi

if [[ ! -d "${AKA_DIR}/.git" ]]; then
    if [[ -e "${AKA_DIR}" ]]; then
        error "${AKA_DIR} exists but is not a Git checkout"
        exit 1
    fi
    info "aka-rk3588 is absent; cloning ${AKA_REPO_URL} to ${AKA_DIR}"
    git clone "${AKA_REPO_URL}" "${AKA_DIR}"
    CLONED=1
fi

AKA_DIR=$(cd "${AKA_DIR}" && pwd -P)
if [[ ${CLONED} -eq 1 && -n "${AKA_REF}" ]]; then
    git -C "${AKA_DIR}" checkout "${AKA_REF}"
elif [[ ${CLONED} -eq 0 && -n "${AKA_REF}" ]]; then
    info "NOTE: ignoring --aka-ref for existing checkout; local state is preserved"
fi

APP_DIR="${AKA_DIR}/zephyr/orangepi_robot_control"
if [[ ! -f "${APP_DIR}/CMakeLists.txt" ]]; then
    error "Zephyr robot application not found: ${APP_DIR}"
    exit 1
fi

if [[ -z "${IVC_SDK_DIR}" ]]; then
    IVC_SDK_DIR="${TGOSIMAGES_ROOT}/../ivc-sdk"
fi
if [[ ! -d "${IVC_SDK_DIR}/.git" ]]; then
    if [[ -e "${IVC_SDK_DIR}" ]]; then
        error "${IVC_SDK_DIR} exists but is not a Git checkout"
        exit 1
    fi
    info "ivc-sdk is absent; cloning ${IVC_SDK_REPO_URL} to ${IVC_SDK_DIR}"
    git clone "${IVC_SDK_REPO_URL}" "${IVC_SDK_DIR}"
    IVC_SDK_CLONED=1
fi
IVC_SDK_DIR=$(cd "${IVC_SDK_DIR}" && pwd -P)
if [[ ${IVC_SDK_CLONED} -eq 1 && -n "${IVC_SDK_REF}" ]]; then
    git -C "${IVC_SDK_DIR}" checkout "${IVC_SDK_REF}"
elif [[ ${IVC_SDK_CLONED} -eq 0 && -n "${IVC_SDK_REF}" ]]; then
    info "NOTE: ignoring --ivc-sdk-ref for existing checkout; local state is preserved"
fi
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
