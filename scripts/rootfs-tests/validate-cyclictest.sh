#!/usr/bin/env bash
set -euo pipefail

die() { echo "cyclictest-validator: $*" >&2; exit 1; }

(($# == 2)) || die 'usage: validate-cyclictest.sh <arch> <cyclictest>'
arch=$1
binary=$2
[[ -f $binary ]] || die "binary does not exist: $binary"

case $arch in
x86_64)
    tool_prefix=''
    syscall_pattern='[[:space:]]syscall([[:space:]]|$)'
    ;;
aarch64)
    tool_prefix=aarch64-linux-gnu-
    syscall_pattern='[[:space:]]svc[[:space:]]'
    ;;
riscv64)
    tool_prefix=riscv64-linux-gnu-
    syscall_pattern='[[:space:]]ecall([[:space:]]|$)'
    ;;
loongarch64)
    tool_prefix=loongarch64-linux-gnu-
    syscall_pattern='[[:space:]]syscall[[:space:]]'
    ;;
*) die "unsupported architecture: $arch" ;;
esac

objdump=${CYCLICTEST_OBJDUMP:-${tool_prefix}objdump}
nm=${CYCLICTEST_NM:-${tool_prefix}nm}
command -v "$objdump" >/dev/null 2>&1 || die "missing disassembler: $objdump"
command -v "$nm" >/dev/null 2>&1 || die "missing symbol reader: $nm"

symbols=$($nm -S -g --defined-only -- "$binary") || die "cannot read symbols: $binary"
for api in sched_getparam sched_getscheduler sched_setscheduler; do
    read -r address size < <(awk -v symbol="$api" '$NF == symbol { print $1, $2; exit }' <<<"$symbols")
    if [[ -z ${address:-} || -z ${size:-} ]]; then
        die "missing scheduler wrapper: $api"
    fi
    start_address=$((16#$address))
    stop_address=$((start_address + 16#$size))
    disassembly=$($objdump -d --start-address="$start_address" --stop-address="$stop_address" -- "$binary") ||
        die "cannot disassemble scheduler wrapper: $api"
    grep -Eq "$syscall_pattern" <<<"$disassembly" ||
        die "$api does not issue a system call"
done

for api in numa_alloc_onnode numa_node_of_cpu numa_parse_cpustring_all numa_run_on_node; do
    grep -Eq "[[:space:]]${api}$" <<<"$symbols" || die "missing NUMA runtime function: $api"
done

all_symbols=$($nm -S --defined-only -- "$binary") || die "cannot read all symbols: $binary"
for symbol in affinity_ip getaddrinfo; do
    ! grep -Eq "[[:space:]]${symbol}$" <<<"$all_symbols" || die "unexpected static glibc dependency path: $symbol"
done
