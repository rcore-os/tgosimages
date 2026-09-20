#!/usr/bin/env bash
set -euo pipefail
platform=$1
step=$2
shift 2
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT_DIR/scripts/lib/utils.sh"
source "$ROOT_DIR/scripts/lib/rootfs.sh"
source "$ROOT_DIR/scripts/lib/rootfs-compose.sh"
source "$ROOT_DIR/scripts/lib/rootfs-disk.sh"
source "$ROOT_DIR/scripts/platform/$platform.sh"
if [[ $step == compose ]]; then
    case $platform in
        phytiumpi) rootfs_inject_guest_stage "$PLATFORM_ROOTFS_DIR/phytiumpi.rootfs.ext2" "$PLATFORM_IMAGES_DIR" ;;
        roc-rk3568-pc|evm3588) rootfs_inject_guest_stage "$PLATFORM_ROOTFS_DIR/$platform.img" "$PLATFORM_IMAGES_DIR" ;;
        *) die "No composition step for $platform" ;;
    esac
else
    "$step" "$@"
fi
