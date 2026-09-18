#!/usr/bin/env bash
set -euo pipefail
image=$1 overlay=$2 reserve=$3
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT_DIR/scripts/lib/utils.sh"
source "$ROOT_DIR/scripts/lib/rootfs-compose.sh"
_rootfs_builder_normalize_overlay_seconds "$overlay"
rootfs_compose_guest_tests_atomic "$image" "$overlay" "$reserve"
