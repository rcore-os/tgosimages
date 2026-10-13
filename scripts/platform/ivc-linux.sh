#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"
source "${ROOT_DIR}/scripts/lib/utils.sh"
trap 'status=$?; error "IVC Linux failed (status=$status, line=$LINENO): $BASH_COMMAND"; exit "$status"' ERR

IVC_SDK_DIR="${IVC_SDK_DIR:-${BUILD_DIR}/ivc-sdk-source}"
LINUX_KDIR="${LINUX_KDIR:-${BUILD_DIR}/orangepi/kernel/orange-pi-6.1-rk35xx}"
IVC_LINUX_OUT="${IVC_LINUX_OUT:-${ROOT_DIR}/IMAGES/orangepi/linux}"
LINUX_IMAGE_NAME="orangepi-5-plus"
IVC_BUILD_DIR="${IVC_BUILD_DIR:-${BUILD_DIR}/ivc-sdk}"
BASE_INITRAMFS="${BASE_INITRAMFS:-${ROOT_DIR}/IMAGES/rootfs/initramfs-aarch64-busybox.cpio.gz}"

[[ -x "${IVC_SDK_DIR}/scripts/build-orangepi-artifacts.sh" ]] ||
    die "ivc-sdk Orange Pi builder not found: ${IVC_SDK_DIR}/scripts/build-orangepi-artifacts.sh"
[[ -f "${LINUX_KDIR}/Makefile" ]] || die "Linux KDIR is not prepared: ${LINUX_KDIR}"
[[ -f "${LINUX_KDIR}/.config" ]] || die "Linux KDIR has no .config: ${LINUX_KDIR}"
[[ -w "${LINUX_KDIR}/.config" && -w "${LINUX_KDIR}" ]] ||
    die "Linux KDIR is not writable by $(id -un): ${LINUX_KDIR}; repair ownership before building"
[[ -s "${BASE_INITRAMFS}" ]] ||
    die "Base AArch64 initramfs is missing: ${BASE_INITRAMFS}"

info "Building AXIVC Linux artifacts against ${LINUX_KDIR}"
(
    cd "${IVC_SDK_DIR}"
    KDIR="${LINUX_KDIR}" \
    KERNEL_BUILD_DIR="${LINUX_KDIR}" \
    BUILD_DIR="${IVC_BUILD_DIR}" \
    JOBS="$(build_jobs)" \
    SKIP_KERNEL_FETCH=1 \
    SKIP_KERNEL_PREPARE=1 \
    KERNEL_CONFIG_SOURCE=existing \
    SKIP_LINUX_IMAGE_BUILD=1 \
    SKIP_ZEPHYR_BUILD=1 \
    ./scripts/build-orangepi-artifacts.sh
)

source "${ROOT_DIR}/scripts/lib/ivc-user-apps.sh"
ensure_musl_toolchain aarch64
build_ivc_roundtrip "${ROOT_DIR}" "${IVC_SDK_DIR}" "${IVC_BUILD_DIR}"

mkdir -p "${IVC_LINUX_OUT}/usr/bin" "${IVC_LINUX_OUT}/lib/modules"
copy_required "${IVC_SDK_DIR}/driver/axvisor.ko" "${IVC_LINUX_OUT}/lib/modules/axvisor.ko"
for program in axivc-pub axivc-sub axivc-pingpong ivc-roundtrip; do
    copy_required "${IVC_BUILD_DIR}/examples/${program}" "${IVC_LINUX_OUT}/usr/bin/${program}"
    chmod 0755 "${IVC_LINUX_OUT}/usr/bin/${program}"
    file "${IVC_LINUX_OUT}/usr/bin/${program}" | grep -q 'ARM aarch64' ||
        die "${program} is not an AArch64 ELF binary"
done

release_file="${LINUX_KDIR}/include/config/kernel.release"
[[ -s "$release_file" ]] || die "Prepared Linux kernel release is missing: $release_file"
expected_release=$(cat "$release_file")
actual_vermagic=$(modinfo -F vermagic "${IVC_LINUX_OUT}/lib/modules/axvisor.ko" 2>/dev/null || true)
[[ -n "${actual_vermagic}" && "${actual_vermagic}" == "${expected_release}"* ]] ||
    die "axvisor.ko vermagic mismatch: expected ${expected_release}, got ${actual_vermagic:-unavailable}"

# Publish the external driver in the same versioned module tree that is
# injected into the independent Linux guest ext4.
module_tree="$IVC_LINUX_OUT/lib/modules/$expected_release"
mkdir -p "$module_tree/extra"
install -D -m 0644 "$IVC_LINUX_OUT/lib/modules/axvisor.ko" "$module_tree/extra/axvisor.ko"
depmod -b "$IVC_LINUX_OUT" "$expected_release"

initramfs_work=$(mktemp -d "${BUILD_DIR}/ivc-linux-initramfs.XXXXXX")
cleanup_initramfs() { rm -rf -- "${initramfs_work}"; }
trap cleanup_initramfs EXIT
command -v fakeroot >/dev/null 2>&1 || die "fakeroot is required to preserve initramfs device nodes"
# One session must own extraction and packing so device types, modes, and
# owners survive even though the host user cannot create real device nodes.
fakeroot bash -s -- "$initramfs_work" "$BASE_INITRAMFS" "$IVC_LINUX_OUT" <<'ARCHIVE'
set -euo pipefail
work=$1 base=$2 output=$3
cd "$work"
gzip -dc -- "$base" | cpio --extract --make-directories --preserve-modification-time --no-absolute-filenames --quiet
mkdir -p root
install -m 0644 "$output/lib/modules/axvisor.ko" root/axvisor.ko
for program in axivc-pub axivc-sub axivc-pingpong ivc-roundtrip; do
    install -m 0755 "$output/usr/bin/$program" "root/$program"
done
find . -print0 | LC_ALL=C sort -z | cpio --null --create --format=newc --quiet >"$output/initramfs.cpio"
ARCHIVE
chmod 0644 "${IVC_LINUX_OUT}/initramfs.cpio"
success "AXIVC Linux artifacts are ready in ${IVC_LINUX_OUT}"
