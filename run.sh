#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}" && pwd -P)
source "${SCRIPT_DIR}/scripts/lib/log.sh"
usage() {
    printf '%s\n' "run.sh: QEMU boot helper for aarch64, riscv64, x86_64."
    printf '%s\n' ''
    printf '%s\n' "Usage:"
    printf '%s\n' "  $0 <aarch64|riscv64|x86_64> [ramfs|rootfs]"
    printf '%s\n' "  $0 -h|--help|help"
    printf '%s\n' ''
    printf '%s\n' "Commands:"
    printf '%s\n' "  help            Show this help and exit"
    printf '%s\n' "  aarch64 ramfs   Run QEMU for aarch64 with initramfs.cpio.gz (initramfs)"
    printf '%s\n' "  aarch64 rootfs  Run QEMU for aarch64 with rootfs.img (ext4 rootfs)"
    printf '%s\n' "  riscv64 ramfs   Run QEMU for riscv64 with initramfs.cpio.gz (initramfs)"
    printf '%s\n' "  riscv64 rootfs  Run QEMU for riscv64 with rootfs.img (ext4 rootfs)"
    printf '%s\n' "  x86_64 ramfs    Run QEMU for x86_64 with initramfs.cpio.gz (initramfs)"
    printf '%s\n' "  x86_64 rootfs   Run QEMU for x86_64 with rootfs.img (ext4 rootfs)"
    printf '%s\n' ''
    printf '%s\n' "Examples:"
    printf '%s\n' "  $0 aarch64 ramfs   # QEMU aarch64, use initramfs.cpio.gz"
    printf '%s\n' "  $0 aarch64 rootfs  # QEMU aarch64, use rootfs.img"
    printf '%s\n' "  $0 x86_64 rootfs   # QEMU x86_64, use rootfs.img"
}

run_qemu_aarch64() {
    local fs_type="${1:-ramfs}"
    local images_dir="${ROOT_DIR}/IMAGES/qemu-aarch64/linux"
    local KERNEL="${images_dir}/Image"
    echo $KERNEL
    if [[ "$fs_type" == "ramfs" ]]; then
        local INITRAMFS="${images_dir}/initramfs.cpio.gz"
        if [[ ! -f "$KERNEL" || ! -f "$INITRAMFS" ]]; then
            error "Missing kernel or initramfs for aarch64."
            exit 1
        fi
        qemu-system-aarch64 \
            -machine virt \
            -cpu cortex-a53 \
            -m 1024 \
            -nographic \
            -kernel "$KERNEL" \
            -initrd "$INITRAMFS" \
            -append "root=/dev/ram rw console=ttyAMA0 init=/init" \
            -no-reboot
    elif [[ "$fs_type" == "rootfs" ]]; then
        local ROOTFS="${images_dir}/rootfs.img"
        if [[ ! -f "$KERNEL" || ! -f "$ROOTFS" ]]; then
            error "Missing kernel or rootfs for aarch64."
            exit 1
        fi
        qemu-system-aarch64 \
            -machine virt \
            -cpu cortex-a53 \
            -m 1024 \
            -nographic \
            -kernel "$KERNEL" \
            -append "root=/dev/vda rw console=ttyAMA0 init=/init" \
            -drive file="$ROOTFS",format=raw,if=virtio \
            -no-reboot
    else
        usage
        exit 2
    fi
}

run_qemu_riscv64() {
    local fs_type="${1:-ramfs}"
    local images_dir="${ROOT_DIR}/IMAGES/qemu-riscv64/linux"
    local KERNEL="${images_dir}/Image"
    if [[ "$fs_type" == "ramfs" ]]; then
        local INITRAMFS="${images_dir}/initramfs.cpio.gz"
        if [[ ! -f "$KERNEL" || ! -f "$INITRAMFS" ]]; then
            error "Missing kernel or initramfs for riscv64."
            exit 1
        fi
        qemu-system-riscv64 \
            -machine virt \
            -m 1024 \
            -nographic \
            -kernel "$KERNEL" \
            -initrd "$INITRAMFS" \
            -append "root=/dev/ram rw console=ttyS0 init=/init" \
            -no-reboot
    elif [[ "$fs_type" == "rootfs" ]]; then
        local ROOTFS="${images_dir}/rootfs.img"
        if [[ ! -f "$KERNEL" || ! -f "$ROOTFS" ]]; then
            error "Missing kernel or rootfs for riscv64."
            exit 1
        fi
        qemu-system-riscv64 \
            -machine virt \
            -m 1024 \
            -nographic \
            -kernel "$KERNEL" \
            -append "root=/dev/vda rw console=ttyS0 init=/init" \
            -drive file="$ROOTFS",format=raw,if=virtio \
            -no-reboot
    else
        usage
        exit 2
    fi
}

run_qemu_x86_64() {
    local fs_type="${1:-ramfs}"
    local images_dir="${ROOT_DIR}/IMAGES/qemu-x86_64/linux"
    local KERNEL="${images_dir}/bzImage"
    if [[ "$fs_type" == "ramfs" ]]; then
        local INITRAMFS="${images_dir}/initramfs.cpio.gz"
        if [[ ! -f "$KERNEL" || ! -f "$INITRAMFS" ]]; then
            error "Missing kernel or initramfs for x86_64."
            exit 1
        fi
        qemu-system-x86_64 \
            -machine q35 \
            -m 1024 \
            -nographic \
            -kernel "$KERNEL" \
            -initrd "$INITRAMFS" \
            -append "root=/dev/ram rw console=ttyS0 init=/init" \
            -no-reboot
    elif [[ "$fs_type" == "rootfs" ]]; then
        local ROOTFS="${images_dir}/rootfs.img"
        if [[ ! -f "$KERNEL" || ! -f "$ROOTFS" ]]; then
            error "Missing kernel or rootfs for x86_64."
            exit 1
        fi
        qemu-system-x86_64 \
            -machine q35 \
            -m 1024 \
            -nographic \
            -kernel "$KERNEL" \
            -append "root=/dev/sda rw console=ttyS0 init=/init" \
            -drive file="$ROOTFS",format=raw,if=ide \
            -no-reboot
    else
        usage
        exit 2
    fi
}

case "${1:-}" in
    ""|-h|--help|help)
        usage
        exit 0
        ;;
    aarch64)
        run_qemu_aarch64 "${2:-ramfs}"
        ;;
    riscv64)
        run_qemu_riscv64 "${2:-ramfs}"
        ;;
    x86_64)
        run_qemu_x86_64 "${2:-ramfs}"
        ;;
    *)
        echo "Unknown command: $1" >&2
        usage
        exit 2
        ;;
esac
