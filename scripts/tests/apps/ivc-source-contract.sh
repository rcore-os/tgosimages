#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
IVC_SDK_DIR=${IVC_SDK_DIR:-${ROOT_DIR}/../ivc-sdk}
TGOSKITS_DIR=${TGOSKITS_DIR:-/home/yanlien/Workspace/QCL/hypervisor/tgoskits-pr}

required=(
  "${IVC_SDK_DIR}/include/axivc/axivc.h"
  "${IVC_SDK_DIR}/driver/ivc.c"
  "${IVC_SDK_DIR}/zephyr/module.yml"
  "${TGOSKITS_DIR}/os/StarryOS/kernel/src/pseudofs/dev/axivc.rs"
  "${TGOSKITS_DIR}/virtualization/axivc"
  "${TGOSKITS_DIR}/virtualization/axhvc/src/ivc.rs"
  "${TGOSKITS_DIR}/test-suit/axvisor/normal/board-orangepi-5-plus/dual-linux-zephyr"
  "${TGOSKITS_DIR}/test-suit/axvisor/normal/board-orangepi-5-plus/dual-starry-zephyr"
  "${TGOSKITS_DIR}/apps/axvisor/normal/board-orangepi-5-plus/ivc"
  "${TGOSKITS_DIR}/benchmarks/axvisor/board-orangepi-5-plus/ivc-benchmark"
)

for path in "${required[@]}"; do
  [[ -e "${path}" ]] || { printf 'missing IVC contract path: %s\n' "${path}" >&2; exit 1; }
done

# This is an input preflight, not a communication test.
printf 'IVC source inputs: READY (run board tests to verify communication)\n'
