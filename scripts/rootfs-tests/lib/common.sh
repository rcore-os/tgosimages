#!/usr/bin/env bash

rootfs_test_csv_contains() {
    local value=$1 csv=$2 item
    local -a items=()
    IFS=, read -r -a items <<<"$csv"
    for item in "${items[@]}"; do
        [[ $item == "$value" ]] && return 0
    done
    return 1
}

rootfs_test_expected_machine() {
    case $1 in
    aarch64) printf '%s\n' 'AArch64' ;;
    riscv64) printf '%s\n' 'RISC-V' ;;
    x86_64) printf '%s\n' 'Advanced Micro Devices X86-64' ;;
    loongarch64) printf '%s\n' 'LoongArch' ;;
    *) return 1 ;;
    esac
}

rootfs_test_cross_prefix() {
    case $1 in
    aarch64) printf '%s\n' 'aarch64-linux-gnu-' ;;
    riscv64) printf '%s\n' 'riscv64-linux-gnu-' ;;
    x86_64) printf '%s\n' 'x86_64-linux-gnu-' ;;
    loongarch64) printf '%s\n' 'loongarch64-linux-gnu-' ;;
    *) return 1 ;;
    esac
}

rootfs_test_download_checked() (
    local url=$1 expected=$2 destination=$3 temporary actual

    cleanup_download() {
        local status=$?
        trap - EXIT INT TERM
        if [[ -n $temporary ]]; then
            rm -f -- "$temporary" || true
        fi
        exit "$status"
    }
    trap cleanup_download EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [[ ! -d $destination ]] || return 1
    temporary=$(mktemp -- "${destination}.tmp.XXXXXX") || return 1
    case $url in
    file://*) cp -- "${url#file://}" "$temporary" || return 1 ;;
    *) curl --fail --location --silent --show-error --output "$temporary" "$url" || return 1 ;;
    esac
    actual=$(sha256sum "$temporary" | awk '{print $1}') || return 1
    [[ $actual == "$expected" ]] || return 1
    mv -T -- "$temporary" "$destination" || return 1
    temporary=''
)

rootfs_test_validate_elf() {
    local arch=$1 file=$2 expected actual
    expected=$(rootfs_test_expected_machine "$arch") || return 1
    [[ -f $file ]] || return 1
    actual=$(LC_ALL=C readelf -h -- "$file" 2>/dev/null |
        awk -F: '/^[[:space:]]*Machine:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }') || return 1
    [[ $actual == "$expected" ]]
}
