#!/usr/bin/env bash
set -euo pipefail
arch=$1 rootfs_type=$2 base_dir=$3 output_dir=$4 outer_overlay=$5 guest_overlay=$6
guest_free=$7 outer_free=$8
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT_DIR/scripts/lib/utils.sh"
source "$ROOT_DIR/scripts/lib/rootfs-compose.sh"
rootfs_create_staging_dir "$output_dir/rootfs-${arch}-${rootfs_type}.img" \
    "qemu-${arch}-${rootfs_type}" staging_dir
empty=$(mktemp -d "${staging_dir}/empty.XXXXXX")
temporary=$(mktemp "${staging_dir}/rootfs-${arch}-${rootfs_type}.compose.XXXXXX")
init_temp=
cleanup() { rm -rf -- "$staging_dir"; }
trap cleanup EXIT
_rootfs_builder_normalize_overlay_seconds "$outer_overlay"
_rootfs_builder_normalize_overlay_seconds "$guest_overlay"
rootfs_compose_test_images "$base_dir/rootfs-${arch}-${rootfs_type}.img" "$outer_overlay" \
    "$guest_overlay" "$empty" "$arch" "$rootfs_type" "$guest_free" "$outer_free" "$temporary"
if [[ $rootfs_type == busybox ]]; then
    init_temp=$(mktemp "${staging_dir}/initramfs-${arch}-busybox.cpio.gz.XXXXXX")
    cp --preserve=all -- "$base_dir/initramfs-${arch}-busybox.cpio.gz" "$init_temp"
    # Reuse BusyBox's rollback-safe two-file publication contract.
    source "$ROOT_DIR/scripts/rootfs/busybox.sh"
    mkfs_publish_pair "$init_temp" "$output_dir/initramfs-${arch}-busybox.cpio.gz" \
        "$temporary" "$output_dir/rootfs-${arch}-busybox.img" "$staging_dir"
    init_temp=
    temporary=
else
    mv -T -- "$temporary" "$output_dir/rootfs-${arch}-${rootfs_type}.img"
    temporary=
fi
trap - EXIT
cleanup
