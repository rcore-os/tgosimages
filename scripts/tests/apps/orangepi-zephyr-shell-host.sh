#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
APP_DIR="${ROOT_DIR}/apps/zephyr/orangepi-shell"
BUILD_DIR="${ZEPHYR_SHELL_BUILD_DIR:-${ROOT_DIR}/build/objects/zephyr/orangepi-5-plus-orangepi-shell}"

for path in CMakeLists.txt prj.conf sample.yaml src/main.cpp src/axivc_tests.cpp \
            src/ivc_benchmark.cpp boards/orangepi_5_plus_rk3588.overlay; do
    [[ -f "${APP_DIR}/${path}" ]] || { echo "missing Shell app file: ${path}" >&2; exit 1; }
done

[[ -s "${BUILD_DIR}/zephyr/zephyr.bin" ]] || {
    echo "build the Orange Pi Shell before running this check" >&2
    exit 1
}

file "${BUILD_DIR}/zephyr/zephyr.bin" | rg -q 'ARM64 boot executable|ARM aarch64|data' || {
    echo "unexpected Orange Pi Shell image type" >&2
    exit 1
}
printf 'Orange Pi Zephyr Shell artifact: READY (communication requires board tests)\n'
