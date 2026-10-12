#!/usr/bin/env bash
#
# Build the `zephyr-triple-guest-functional` Zephyr client image for the Orange
# Pi 5 Plus Linux + StarryOS + Zephyr three-guest functional test.
#
# This is a thin, reproducible profile on top of the existing TGOSImages Orange
# Pi Zephyr build base: it calls `scripts/os/zephyr.sh orangepi-5-plus`, so the
# fixed Zephyr ref, `patches/zephyr`, the Zephyr SDK, the Python environment and
# the `orangepi_5_plus_rk3588` board (NS16550 UART, ARM arch timer, DTB handling)
# are reused unchanged. Only the application and the artifact name are specific
# to this profile.
#
# The default `orangepi-5-plus` latency_measure build is untouched: this profile
# uses its own Zephyr build tree
# (`build/objects/zephyr/orangepi-5-plus-zephyr-triple-guest-functional`) and its
# own image name, so it never overwrites `IMAGES/orangepi/zephyr/orangepi-5-plus*`.
#
# One-call entry (from the tgosimages repository root):
#   ./scripts/apps/zephyr-triple-guest-functional.sh
#   ./scripts/apps/zephyr-triple-guest-functional.sh clean
#
# `clean` removes only this profile's build tree and its three artifacts; it never
# wipes the shared `IMAGES/orangepi/zephyr` directory.
#
# Equivalent direct invocation of the Orange Pi Zephyr base:
#   ./scripts/os/zephyr.sh orangepi-5-plus \
#     --app "$PWD/apps/zephyr-triple-guest-functional" \
#     --images-dir "$PWD/IMAGES/orangepi/zephyr" \
#     --image-name zephyr-triple-guest-functional
#
# Artifacts (standard Orange Pi Zephyr image directory):
#   IMAGES/orangepi/zephyr/zephyr-triple-guest-functional
#   IMAGES/orangepi/zephyr/zephyr-triple-guest-functional.elf
#   IMAGES/orangepi/zephyr/zephyr-triple-guest-functional.dtb
#
# Any extra arguments are forwarded to scripts/os/zephyr.sh, except that the
# profile's --app, --images-dir and --image-name are pinned by this entry point.
# `clean` must be the only argument; it removes only this profile's build tree
# and the three artifacts below.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"

source "${ROOT_DIR}/scripts/lib/log.sh"

# Formal image name. Keep the three-guest meaning explicit; do not shorten it to
# an ambiguous `guest-tests-zephyr-shell`.
IMAGE_NAME="zephyr-triple-guest-functional"
APP_DIR="${ROOT_DIR}/apps/zephyr-triple-guest-functional"
IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi/zephyr"
# Mirror `ZEPHYR_BUILD_SUBDIR` in scripts/os/zephyr.sh: the Orange Pi base plus
# the application basename appended by `--app`.
BUILD_SUBDIR="objects/zephyr/orangepi-5-plus-$(basename -- "${APP_DIR}")"

if [[ "${1:-}" == clean ]]; then
    if [[ $# -ne 1 ]]; then
        error "clean must be the only argument"
        exit 2
    fi
    info "Removing only the ${IMAGE_NAME} build tree and artifacts"
    rm -rf -- "${BUILD_DIR}/${BUILD_SUBDIR}"
    rm -f -- \
        "${IMAGES_DIR}/${IMAGE_NAME}" \
        "${IMAGES_DIR}/${IMAGE_NAME}.elf" \
        "${IMAGES_DIR}/${IMAGE_NAME}.dtb"
    success "Clean finished"
    exit 0
fi

for arg in "$@"; do
    if [[ "${arg}" == clean ]]; then
        error "clean must be the only argument"
        exit 2
    fi
done

for required in CMakeLists.txt prj.conf src/main.c \
    boards/orangepi_5_plus_rk3588.overlay; do
    if [[ ! -s "${APP_DIR}/${required}" ]]; then
        error "missing Zephyr application source: ${APP_DIR}/${required}"
        exit 1
    fi
done

info "Building Zephyr three-guest functional image ${IMAGE_NAME}"
info "Application: ${APP_DIR}"
info "Output: ${IMAGES_DIR}"

exec "${ROOT_DIR}/scripts/os/zephyr.sh" orangepi-5-plus \
    "$@" \
    --app "${APP_DIR}" \
    --images-dir "${IMAGES_DIR}" \
    --image-name "${IMAGE_NAME}"
