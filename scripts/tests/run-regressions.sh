#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"

python_tests=(
    scripts/tests/build/build-graph.py
    scripts/tests/build/qemu-parallel.py
    scripts/tests/build/build-review-regressions.py
    scripts/tests/rootfs/rootfs-graph.py
)

shell_tests=(
    scripts/tests/build/build-performance.sh
    scripts/tests/build/download-archive.sh
    scripts/tests/build/platform-script-boundaries.sh
    scripts/tests/rootfs/rootfs-compose.sh
    scripts/tests/rootfs/rootfs-disk.sh
    scripts/tests/rootfs/rootfs-plugin-framework.sh
    scripts/tests/rootfs/qemu-rootfs-test-options.sh
    scripts/tests/rootfs/rootfs-builder-options.sh
    scripts/tests/rootfs/rootfs-nested-content-test.sh
    scripts/tests/platform/orangepi-rootfs-flow.sh
    scripts/tests/platform/starry-release-smoke.sh
)

for test in "${python_tests[@]}"; do
    printf 'RUN %s\n' "$test"
    python3 "$test"
done

for test in "${shell_tests[@]}"; do
    printf 'RUN %s\n' "$test"
    bash "$test"
done
