#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/log.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/build-performance.sh"
ROOT_DIR=$(cd "$TGOS_BUILD_LIB_DIR/../.." && pwd -P)
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"

########################################
# Config
########################################

export DEBIAN_FRONTEND=noninteractive
export TZ="${TZ:-Etc/UTC}"

WORKDIR="${ORANGEPI_UBOOT_WORKDIR:-${PWD}/build/orangepi-u-boot}"

TMPROOT="${WORKDIR}/tmp"
mkdir -p "${TMPROOT}"

export TMPDIR="${TMPROOT}"
export TEMP="${TMPROOT}"
export TMP="${TMPROOT}"

RKBIN_SOURCE="https://github.com/rockchip-linux/rkbin/archive/refs/heads/master.tar.gz"

ATF_VERSION="v2.12.0"
ATF_SOURCE="https://github.com/ARM-software/arm-trusted-firmware/archive/refs/tags/${ATF_VERSION}.tar.gz"

U_BOOT_VERSION="v2025.04"
U_BOOT_SOURCE="https://github.com/u-boot/u-boot/archive/refs/tags/${U_BOOT_VERSION}.tar.gz"

BOARD="orangepi5"
NAME="u-boot-${BOARD}-spi"
DEFCONFIG="orangepi-5-rk3588s"

# U-Boot for AArch64 platforms generally uses:
export ARCH=arm
export CROSS_COMPILE=aarch64-linux-gnu-

########################################
# Helpers
########################################

build_step() {
    info "Step $1: $2"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        error "Command not found: $1"
        exit 1
    }
}

########################################
# Prepare directories
########################################

mkdir -p \
    "${WORKDIR}/src/rkbin" \
    "${WORKDIR}/src/atf" \
    "${WORKDIR}/src/u-boot" \
    "${WORKDIR}/rkbin" \
    "${WORKDIR}/atf" \
    "${WORKDIR}/build/u-boot" \
    "${WORKDIR}/out"

########################################
# Step 1: install dependencies
########################################

build_step "1/6" "install dependencies"

sudo ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
echo "${TZ}" | sudo tee /etc/timezone >/dev/null

sudo apt-get update
sudo apt-get install --no-install-recommends -y \
    bc \
    bison \
    build-essential \
    ca-certificates \
    coccinelle \
    curl \
    device-tree-compiler \
    dfu-util \
    efitools \
    flex \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    gdisk \
    git \
    graphviz \
    imagemagick \
    liblz4-tool \
    libgnutls28-dev \
    libguestfs-tools \
    libncurses-dev \
    libpython3-dev \
    libsdl2-dev \
    libssl-dev \
    lz4 \
    lzma \
    lzma-alone \
    openssl \
    pkg-config \
    python3 \
    python3-asteval \
    python3-coverage \
    python3-filelock \
    python3-pkg-resources \
    python3-pycryptodome \
    python3-pyelftools \
    python3-pytest \
    python3-pytest-xdist \
    python3-sphinxcontrib.apidoc \
    python3-sphinx-rtd-theme \
    python3-subunit \
    python3-testtools \
    python3-virtualenv \
    swig \
    uuid-dev

need_cmd curl
need_cmd tar
need_cmd make
need_cmd "${CROSS_COMPILE}gcc"

########################################
# Step 2: download rkbin and extract tpl
########################################

build_step "2/6" "download rkbin and extract tpl.bin"

rm -rf "${WORKDIR}/src/rkbin"
mkdir -p "${WORKDIR}/src/rkbin"

curl -L "${RKBIN_SOURCE}" | tar -xz -C "${WORKDIR}/src/rkbin" --strip-components=1

TPL_FILE="$(
    ls -1 "${WORKDIR}/src/rkbin/bin/rk35" | \
    grep -E 'rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v[0-9.]+\.bin' | \
    tail -n 1
)"

if [ -z "${TPL_FILE}" ]; then
    error "failed to find rk3588 DDR binary in rkbin"
    exit 1
fi

cp "${WORKDIR}/src/rkbin/bin/rk35/${TPL_FILE}" "${WORKDIR}/rkbin/tpl.bin"

info "TPL_FILE=${TPL_FILE}"
info "TPL => ${WORKDIR}/rkbin/tpl.bin"

########################################
# Step 3: build ATF BL31
########################################

build_step "3/6" "download and build ARM Trusted Firmware (BL31)"

rm -rf "${WORKDIR}/src/atf"
mkdir -p "${WORKDIR}/src/atf"

curl -L "${ATF_SOURCE}" | tar -xz -C "${WORKDIR}/src/atf" --strip-components=1

pushd "${WORKDIR}/src/atf" >/dev/null
CFLAGS=--param=min-pagesize=0 build_make DEBUG=0 PLAT=rk3588 bl31
cp build/rk3588/release/bl31/bl31.elf "${WORKDIR}/atf/bl31.elf"
popd >/dev/null

if [ ! -f "${WORKDIR}/atf/bl31.elf" ]; then
    error "BL31 build failed, ${WORKDIR}/atf/bl31.elf not found"
    exit 1
fi

info "BL31 => ${WORKDIR}/atf/bl31.elf"

########################################
# Step 4: download U-Boot
########################################

build_step "4/6" "download U-Boot"

rm -rf "${WORKDIR}/src/u-boot"
mkdir -p "${WORKDIR}/src/u-boot"

curl -L "${U_BOOT_SOURCE}" | tar -xz -C "${WORKDIR}/src/u-boot" --strip-components=1

########################################
# Step 5: build U-Boot
########################################

build_step "5/6" "build U-Boot for Orange Pi 5"

export ROCKCHIP_TPL="${WORKDIR}/rkbin/tpl.bin"
export BL31="${WORKDIR}/atf/bl31.elf"

rm -rf "${WORKDIR}/build/u-boot"
mkdir -p "${WORKDIR}/build/u-boot"

pushd "${WORKDIR}/src/u-boot" >/dev/null

build_make O="${WORKDIR}/build/u-boot" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    "${DEFCONFIG}_defconfig"

build_make O="${WORKDIR}/build/u-boot" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    HOSTLDLIBS_mkimage="-lssl -lcrypto"

popd >/dev/null

if [ ! -f "${WORKDIR}/build/u-boot/u-boot-rockchip-spi.bin" ]; then
    error "U-Boot build failed, output bin not found"
    exit 1
fi

########################################
# Step 6: collect output
########################################

build_step "6/6" "collect output"

cp "${WORKDIR}/build/u-boot/u-boot-rockchip-spi.bin" \
   "${WORKDIR}/out/${NAME}.bin"

success "Done."
info "Output file: ${WORKDIR}/out/${NAME}.bin"
ls -lh "${WORKDIR}/out/${NAME}.bin"
