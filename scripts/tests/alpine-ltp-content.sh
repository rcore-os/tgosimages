#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
IMAGE_DIR="${ROOT_DIR}/IMAGES/rootfs"
LTP_VERSION="20260529"
ARCHES=(aarch64 loongarch64 riscv64 x86_64)

usage() {
    printf 'Usage: %s [--image-dir <dir>]\n' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-dir)
            [[ $# -ge 2 ]] || {
                usage >&2
                exit 2
            }
            IMAGE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

for tool in debugfs readelf; do
    command -v "${tool}" >/dev/null 2>&1 || {
        printf 'missing required tool: %s\n' "${tool}" >&2
        exit 1
    }
done

TMP_DIR=$(mktemp -d /tmp/alpine-ltp-content.XXXXXX)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

debugfs_stat() {
    local image="$1"
    local guest_path="$2"

    debugfs -R "stat ${guest_path}" "${image}" 2>/dev/null
}

debugfs_path_exists() {
    local image="$1"
    local guest_path="$2"

    debugfs_stat "${image}" "${guest_path}" | grep -q '^Inode:'
}

debugfs_dump_required() {
    local image="$1"
    local guest_path="$2"
    local host_path="$3"

    rm -f -- "${host_path}"
    debugfs -R "dump -p ${guest_path} ${host_path}" "${image}" >/dev/null 2>&1
    [[ -f "${host_path}" ]] || {
        printf 'missing required image path: %s in %s\n' "${guest_path}" "${image}" >&2
        exit 1
    }
}

expected_machine() {
    case "$1" in
        aarch64) printf 'AArch64\n' ;;
        loongarch64) printf 'LoongArch\n' ;;
        riscv64) printf 'RISC-V\n' ;;
        x86_64) printf 'Advanced Micro Devices X86-64\n' ;;
        *) return 1 ;;
    esac
}

for arch in "${ARCHES[@]}"; do
    image="${IMAGE_DIR}/rootfs-${arch}-alpine.img"
    [[ -f "${image}" ]] || {
        printf 'missing Alpine rootfs image: %s\n' "${image}" >&2
        exit 1
    }

    arch_dir="${TMP_DIR}/${arch}"
    mkdir -p "${arch_dir}"
    version_file="${arch_dir}/Version"
    runtest_file="${arch_dir}/syscalls"
    testcase_file="${arch_dir}/timer_create02"

    debugfs_dump_required "${image}" /opt/ltp/Version "${version_file}"
    debugfs_dump_required "${image}" /opt/ltp/runtest/syscalls "${runtest_file}"
    debugfs_dump_required "${image}" /opt/ltp/testcases/bin/timer_create02 "${testcase_file}"

    version=$(tr -d '\r\n' < "${version_file}")
    [[ "${version}" == "${LTP_VERSION}" ]] || {
        printf 'unexpected LTP version for %s: %s\n' "${arch}" "${version}" >&2
        exit 1
    }

    for excluded in timer_create01 timer_create03; do
        if debugfs_path_exists "${image}" "/opt/ltp/testcases/bin/${excluded}"; then
            printf 'unexpected testcase binary for %s: %s\n' "${arch}" "${excluded}" >&2
            exit 1
        fi
        if awk -v testcase="${excluded}" '$1 == testcase { found = 1 } END { exit !found }' "${runtest_file}"; then
            printf 'unexpected runtest entry for %s: %s\n' "${arch}" "${excluded}" >&2
            exit 1
        fi
    done

    [[ -x "${testcase_file}" ]] || {
        printf 'timer_create02 is not executable for %s\n' "${arch}" >&2
        exit 1
    }
    awk '$1 == "timer_create02" { matches += 1 } END { exit matches != 1 }' "${runtest_file}" || {
        printf 'timer_create02 runtest entry is missing or duplicated for %s\n' "${arch}" >&2
        exit 1
    }

    readelf_header=$(readelf -h "${testcase_file}")
    grep -q 'Class:[[:space:]]*ELF64' <<< "${readelf_header}" || {
        printf 'timer_create02 is not ELF64 for %s\n' "${arch}" >&2
        exit 1
    }
    machine=$(expected_machine "${arch}")
    grep -q "Machine:[[:space:]]*${machine}" <<< "${readelf_header}" || {
        printf 'unexpected timer_create02 ELF machine for %s\n' "${arch}" >&2
        exit 1
    }

    printf 'verified Alpine LTP image: %s\n' "${arch}"
done
