#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT_DIR/scripts/lib/utils.sh"

package=${ORANGEPI_AKA_PACKAGE:-$ROOT_DIR/IMAGES/orangepi/aka}
provided=${ORANGEPI_AKA_PACKAGE_PROVIDED:-0}
[[ -z ${ORANGEPI_AKA_PACKAGE:-} ]] || provided=${ORANGEPI_AKA_PACKAGE_PROVIDED:-1}
aka=${ORANGEPI_AKA_SOURCE_DIR:-${AKA_RK3588_DIR:-}}
sdk=${IVC_SDK_DIR:-}
runtime=${ORANGEPI_AKA_RUNTIME_DIR:-}
includes=${ORANGEPI_AKA_INCLUDE_DIR:-}
config=${ORANGEPI_AKA_CONFIG_DIR:-}
cc=${ORANGEPI_AKA_CC:-}
cxx=${ORANGEPI_AKA_CXX:-}
sysroot=${ORANGEPI_AKA_SYSROOT:-}
lock=${ORANGEPI_AKA_DEPENDENCY_LOCK:-$ROOT_DIR/scripts/apps/aka-runtime.lock.json}
sdk_ref=${IVC_SDK_REF:-HEAD}
sdk_repo=${IVC_SDK_REPO_URL:-https://github.com/rcore-os/ivc-sdk.git}
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 || $1 == --help || $1 == -h ]] || { echo "Missing value: $1" >&2; exit 2; }
    case $1 in
        --aka-dir) aka=$2 ;;
        --ivc-sdk-dir) sdk=$2 ;;
        --ivc-sdk-ref) sdk_ref=$2 ;;
        --ivc-sdk-repo-url) sdk_repo=$2 ;;
        --output-dir) package=$2; provided=0 ;;
        --help|-h)
            echo "Usage: orangepi-aka-package.sh [--aka-dir DIR] [--ivc-sdk-dir DIR] [--output-dir DIR]"
            echo "Downloads SHA256-locked Ubuntu arm64 dependencies, builds AKA, and records package provenance."
            echo "ORANGEPI_AKA_SYSROOT selects a read-only target SDK; otherwise a locked sysroot is managed in build/."
            echo "Optional inputs: ORANGEPI_AKA_CONFIG_DIR, ORANGEPI_AKA_CC/CXX, ORANGEPI_AKA_RUNTIME_DIR/INCLUDE_DIR."
            exit 0 ;;
        *) echo "Unknown AKA package option: $1" >&2; exit 2 ;;
    esac
    shift 2
done
helper="$ROOT_DIR/scripts/lib/python/aka-package.py"
if [[ $provided == 1 ]]; then
    python3 "$helper" validate "$package" --with-single
    info "Using provided AKA runtime package: $package"
    exit 0
fi
aka_provided=0; sdk_provided=0
[[ -z $aka ]] || aka_provided=1
[[ -z $sdk ]] || sdk_provided=1
aka=${aka:-$BUILD_DIR/aka-rk3588}
sdk=${sdk:-$BUILD_DIR/ivc-sdk-source}
build_prepare_checkout "$aka" "${AKA_RK3588_REPO_URL:-https://github.com/bullhh/aka-rk3588.git}" "${AKA_RK3588_REF:-dual}" "$aka_provided"
# Reuse the SDK revision prepared by the ivc dependency, without cleaning it.
[[ ! -e $sdk/.git ]] || sdk_provided=1
build_prepare_checkout "$sdk" "$sdk_repo" "$sdk_ref" "$sdk_provided"
if [[ -z $runtime && -z $includes ]]; then
    if [[ -n $sysroot ]]; then
        # A caller-selected target SDK is an input, even if it contains an
        # old managed manifest. Never extract default distro packages into it.
        sysroot=$(realpath -e -- "$sysroot")
        includes="$sysroot/usr/include"
        [[ -d $includes ]] || die "Caller target sysroot lacks usr/include; provide both ORANGEPI_AKA_RUNTIME_DIR and ORANGEPI_AKA_INCLUDE_DIR"
        runtime_stage=$(mktemp -d "${TMPDIR:-/tmp}/aka-target-runtime.XXXXXX")
        trap 'rm -rf -- "$runtime_stage"' EXIT
        runtime="$runtime_stage/runtime"
        python3 "$helper" sysroot-runtime --sysroot "$sysroot" --output "$runtime"
    else
        sysroot="$BUILD_DIR/aka-sysroot"
        python3 "$helper" runtime --lock "$lock" --cache "${BUILD_CACHE_DIR:-$ROOT_DIR/build/.cache}/aka-debs" --sysroot "$sysroot"
        runtime="$sysroot/runtime"
        includes="$sysroot/usr/include"
    fi
fi
[[ -d $runtime && -d $includes ]] || die "Provide both ORANGEPI_AKA_RUNTIME_DIR and ORANGEPI_AKA_INCLUDE_DIR"
if [[ -z $cc ]]; then
    shopt -s nullglob
    candidates=("$BUILD_DIR"/orangepi/toolchains/*/bin/aarch64*-gcc)
    for candidate in "${candidates[@]}"; do
        [[ -x $candidate ]] || continue
        cc=$candidate; break
    done
    [[ -n $cc ]] || cc=$(command -v aarch64-linux-gnu-gcc-9 || command -v aarch64-linux-gnu-gcc || true)
fi
cxx=${cxx:-${cc%gcc}g++}
if [[ $cc == *-gcc-[0-9]* && -z ${ORANGEPI_AKA_CXX:-} ]]; then cxx=${cc/-gcc-/-g++-}; fi
[[ -x $cc && -x $cxx ]] || die "GNU AArch64 compilers not found; set ORANGEPI_AKA_CC and ORANGEPI_AKA_CXX"
arguments=(--aka-dir "$aka" --ivc-sdk-dir "$sdk" --runtime-dir "$runtime" --include-dir "$includes"
           --cc "$cc" --cxx "$cxx" --build-dir "$BUILD_DIR/objects/aka-perception" --output-dir "$package")
[[ -z $config ]] || arguments+=(--config-dir "$config")
[[ -z $sysroot ]] || arguments+=(--sysroot "$sysroot")
JOBS=$(build_jobs) bash "$ROOT_DIR/scripts/apps/orangepi-aka-perception.sh" "${arguments[@]}"
