#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
work=$(mktemp -d /tmp/qemu-rootfs-options.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

tests=0
fail() { printf 'not ok %s - %s\n' "$tests" "$*" >&2; exit 1; }
pass() { printf 'ok %s - %s\n' "$tests" "$*"; }
run_ok() {
    local message=$1
    shift
    tests=$((tests + 1))
    if ! "$@" >"$work/stdout" 2>"$work/stderr"; then
        sed -n '1,160p' "$work/stderr" >&2
        fail "$message"
    fi
    pass "$message"
}
run_fail() {
    local message=$1
    shift
    tests=$((tests + 1))
    if "$@" >"$work/stdout" 2>"$work/stderr"; then
        fail "$message (unexpected success)"
    fi
    pass "$message"
}

# shellcheck source=../platform/qemu.sh
source "$repo_root/scripts/platform/qemu.sh"
# shellcheck source=../lib/utils.sh
source "$repo_root/scripts/lib/utils.sh"
# shellcheck source=../lib/rootfs-compose.sh
source "$repo_root/scripts/lib/rootfs-compose.sh"

make_ext4() {
    truncate -s 12M "$1"
    mkfs.ext4 -F -q "$1"
}

dump_ext4_path() {
    debugfs -R "dump $2 $3" "$1" >/dev/null 2>&1
}

test_parse_routing() (
    ARCH=x86_64 OS=linux
    qemu_rootfs_parse_args make-target --outer-tests none --guest-tests 'cyclictest; touch /tmp/nope' \
        --guest-free-size '12 M' --outer-free-size 34M KCFLAGS=-g
    [[ ${BUILD_ARGS[*]} == 'make-target KCFLAGS=-g' ]]
    [[ ${#ROOTFS_BUILD_ARGS[@]} -eq 8 ]]
    [[ ${ROOTFS_BUILD_ARGS[0]} == --outer-tests && ${ROOTFS_BUILD_ARGS[1]} == none ]]
    [[ ${ROOTFS_BUILD_ARGS[2]} == --guest-tests && ${ROOTFS_BUILD_ARGS[3]} == 'cyclictest; touch /tmp/nope' ]]
    [[ ${ROOTFS_BUILD_ARGS[4]} == --guest-free-size && ${ROOTFS_BUILD_ARGS[5]} == '12 M' ]]
    [[ ${ROOTFS_BUILD_ARGS[6]} == --outer-free-size && ${ROOTFS_BUILD_ARGS[7]} == 34M ]]
    [[ $QEMU_OUTER_FREE_SIZE == 34M ]]
)
run_ok 'rootfs-only options are routed as an argument array' test_parse_routing

test_parse_defaults() (
    ARCH=x86_64 OS=linux
    qemu_rootfs_parse_args make-target
    [[ ${BUILD_ARGS[*]} == make-target ]]
    [[ ${#ROOTFS_BUILD_ARGS[@]} -eq 0 ]]
    [[ -z ${QEMU_OUTER_FREE_SIZE:-} ]]
)
run_ok 'omitted rootfs options stay omitted for builder defaults' test_parse_defaults

for option in --outer-tests --guest-tests --guest-free-size --outer-free-size; do
    run_fail "$option requires one value" bash -c '
        source "$1/scripts/platform/qemu.sh"
        ARCH=x86_64 OS=linux
        qemu_rootfs_parse_args "$2"
    ' _ "$repo_root" "$option"
done
run_fail 'rootfs option does not consume the next option as its value' bash -c '
    source "$1/scripts/platform/qemu.sh"
    source "$1/scripts/lib/utils.sh"
    ARCH=x86_64 OS=linux
    qemu_rootfs_parse_args --outer-tests --guest-tests cyclictest
' _ "$repo_root"

test_builder_argv_is_literal() (
    local fake_root="$work/fake-root"
    local args_log="$work/builder.args"
    local injection_marker="$work/option-injection"
    mkdir -p "$fake_root/scripts/rootfs" "$fake_root/scripts/platform" "$fake_root/IMAGES/rootfs"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\0" "$@" >"$QEMU_TEST_ARGS_LOG"' >"$fake_root/scripts/rootfs/alpine.sh"
    chmod +x "$fake_root/scripts/rootfs/alpine.sh"
    ROOT_DIR=$fake_root SCRIPT_DIR="$fake_root/scripts/platform" ARCH=x86_64 QEMU_TEST_ARGS_LOG=$args_log
    export QEMU_TEST_ARGS_LOG
    ROOTFS_BUILD_ARGS=(--guest-tests "one; touch $injection_marker" --outer-free-size '7 M')
    qemu_rootfs_build_step alpine
    mapfile -d '' -t got <"$args_log"
    [[ ${#got[@]} -eq 7 ]]
    [[ ${got[0]} == x86_64 && ${got[1]} == --out_dir && ${got[2]} == "$fake_root/IMAGES/rootfs" ]]
    [[ ${got[3]} == --guest-tests && ${got[4]} == "one; touch $injection_marker" ]]
    [[ ${got[5]} == --outer-free-size && ${got[6]} == '7 M' ]]
    [[ ! -e $injection_marker ]]
)
run_ok 'rootfs builder receives literal safely quoted argv' test_builder_argv_is_literal

test_parallel_routing_and_order() (
    local call_log="$work/order.calls"
    ARCH=x86_64 OS=linux ROOTFS_BUILDERS=(alpine)
    BUILD_ARGS=('make target' 'X=two words')
    ROOTFS_BUILD_ARGS=(--guest-tests 'one two')
    new_log_dir() { mkdir -p "$work/order-log"; printf '%s\n' "$work/order-log"; }
    linux() { printf 'os' >>"$call_log"; printf ':%s' "$@" >>"$call_log"; printf '\n' >>"$call_log"; }
    qemu_rootfs_build_step() { printf 'rootfs:%s' "$1" >>"$call_log"; printf ':%s' "${ROOTFS_BUILD_ARGS[@]}" >>"$call_log"; printf '\n' >>"$call_log"; }
    run_parallel_functions() {
        local action=$1
        shift
        while [[ $1 != -- ]]; do
            local step=$1
            shift
            "$step" 'make target' 'X=two words'
        done
        shift
    }
    qemu_rootfs_inject_platform_dir() { printf 'inject\n' >>"$call_log"; }
    qemu_build_os_and_rootfs linux linux
    [[ $(sed -n '1p' "$call_log") == 'os:make target:X=two words' ]]
    [[ $(sed -n '2p' "$call_log") == 'rootfs:alpine:--guest-tests:one two' ]]
    [[ $(sed -n '3p' "$call_log") == inject ]]
)
run_ok 'parallel OS/rootfs routing preserves argv and injection runs afterward' test_parallel_routing_and_order

test_injection_routing_and_order() (
    local fake_root="$work/inject-root"
    local call_log="$work/inject.calls"
    ROOT_DIR=$fake_root BUILD_DIR="$fake_root/build" ARCH=aarch64
    PLATFORM_IMAGES_DIR="$fake_root/IMAGES/qemu-aarch64"
    ROOTFS_BUILDERS=(busybox alpine debian)
    QEMU_OUTER_FREE_SIZE=19M
    mkdir -p "$BUILD_DIR" "$PLATFORM_IMAGES_DIR/linux" "$fake_root/IMAGES/rootfs"
    printf kernel >"$PLATFORM_IMAGES_DIR/linux/linux-qemu"
    : >"$fake_root/IMAGES/rootfs/initramfs-aarch64-busybox.cpio.gz"
    : >"$fake_root/IMAGES/rootfs/rootfs-aarch64-busybox.img"
    : >"$fake_root/IMAGES/rootfs/rootfs-aarch64-alpine.img"
    : >"$fake_root/IMAGES/rootfs/rootfs-aarch64-debian.img"
    qemu_prepare_ivc_payloads() {
        mkdir -p "$BUILD_DIR/qemu-aarch64-ivc-rootfs-overlay/opt/ivc" "$PLATFORM_IMAGES_DIR/arceos"
        printf ivc >"$BUILD_DIR/qemu-aarch64-ivc-rootfs-overlay/opt/ivc/tool"
        printf ivc >"$PLATFORM_IMAGES_DIR/arceos/ivc-only"
    }
    qemu_ivc_validate_staged_payloads() { :; }
    rootfs_stage_guest_tree() { mkdir -p "$1/guest"; cp -a "$2/." "$1/guest/"; }
    rootfs_inject_guest_stage() {
        printf 'initramfs:%s:%s\n' "$1" "$2" >>"$call_log"
        # Model cpio packaging reading the private staging file and advancing
        # its atime after the initial timestamp normalization.
        cat "$2/linux/linux-qemu" >/dev/null
    }
    rootfs_inject_outer_payload_atomic() {
        local ivc_guest=no
        rootfs_validate_payload_tree "$2" || return 1
        [[ ! -e $2/arceos/ivc-only ]] || ivc_guest=yes
        printf 'atomic:%s:%s:%s:%s:%s:ivc-guest=%s\n' "$1" "$2" "$3" "$4" "$5" "$ivc_guest" >>"$call_log"
    }
    qemu_rootfs_inject_platform_dir || return 1
    [[ $(grep -c '^initramfs:' "$call_log") -eq 1 ]]
    [[ $(grep -c '^atomic:' "$call_log") -eq 3 ]]
    [[ $(sed -n '1p' "$call_log") == initramfs:* ]]
    grep -q "atomic:$fake_root/IMAGES/rootfs/rootfs-aarch64-busybox.img:.*:.*:rootfs-aarch64-busybox.img:19M" "$call_log"
    grep -q "atomic:$fake_root/IMAGES/rootfs/rootfs-aarch64-alpine.img:.*:$BUILD_DIR/qemu-aarch64-ivc-rootfs-overlay:rootfs-aarch64-alpine.img:19M" "$call_log"
    grep -q "atomic:$fake_root/IMAGES/rootfs/rootfs-aarch64-debian.img:.*:.*:rootfs-aarch64-debian.img:19M" "$call_log"
    grep -q 'rootfs-aarch64-busybox.img:19M:ivc-guest=no$' "$call_log"
    grep -q 'rootfs-aarch64-alpine.img:19M:ivc-guest=yes$' "$call_log"
    grep -q 'rootfs-aarch64-debian.img:19M:ivc-guest=no$' "$call_log"
)
run_ok 'BusyBox initramfs stays separate and each ext4 image gets one atomic call' test_injection_routing_and_order

test_collision_precedes_output_touch() (
    local fake_root="$work/collision-root"
    local call_log="$work/collision.calls"
    ROOT_DIR=$fake_root BUILD_DIR="$fake_root/build" ARCH=x86_64
    PLATFORM_IMAGES_DIR="$fake_root/IMAGES/qemu-x86_64"
    ROOTFS_BUILDERS=(busybox)
    QEMU_OUTER_FREE_SIZE=
    mkdir -p "$BUILD_DIR" "$PLATFORM_IMAGES_DIR" "$fake_root/IMAGES/rootfs"
    printf collision >"$PLATFORM_IMAGES_DIR/rootfs-x86_64-busybox.img"
    : >"$fake_root/IMAGES/rootfs/initramfs-x86_64-busybox.cpio.gz"
    : >"$fake_root/IMAGES/rootfs/rootfs-x86_64-busybox.img"
    rootfs_stage_guest_tree() { mkdir -p "$1/guest"; cp -a "$2/." "$1/guest/"; }
    rootfs_inject_guest_stage() { printf touched >>"$call_log"; }
    rootfs_inject_outer_payload_atomic() { printf touched >>"$call_log"; }
    ! (qemu_rootfs_inject_platform_dir)
    [[ ! -e $call_log ]]
    [[ -z $(find "$BUILD_DIR" -mindepth 1 -name 'qemu-rootfs-*' -print -quit) ]]
)
run_ok 'protected platform basename collision is rejected before any injection' test_collision_precedes_output_touch

test_real_ext4_platform_injection() (
    local fake_root="$work/ext4-root"
    local outer="$fake_root/IMAGES/rootfs/rootfs-x86_64-debian.img"
    local nested="$work/nested.img"
    local seed="$work/ext4-seed"
    local before_dump="$work/nested-before.img"
    local after_dump="$work/nested-after.img"
    ROOT_DIR=$fake_root BUILD_DIR="$fake_root/build" ARCH=x86_64
    PLATFORM_IMAGES_DIR="$fake_root/IMAGES/qemu-x86_64"
    ROOTFS_BUILDERS=(debian)
    QEMU_OUTER_FREE_SIZE=2M
    mkdir -p "$BUILD_DIR" "$PLATFORM_IMAGES_DIR/linux" "$(dirname -- "$outer")" "$seed/guest"
    printf kernel >"$PLATFORM_IMAGES_DIR/linux/linux-qemu"
    touch -d @1700000000.5 "$PLATFORM_IMAGES_DIR/linux/linux-qemu" "$PLATFORM_IMAGES_DIR/linux" "$PLATFORM_IMAGES_DIR"
    make_ext4 "$nested"
    make_ext4 "$outer"
    cp "$nested" "$seed/guest/rootfs-x86_64-debian.img"
    _rootfs_inject_tree_via_debugfs "$outer" "$seed"
    dump_ext4_path "$outer" /guest/rootfs-x86_64-debian.img "$before_dump"
    qemu_rootfs_inject_platform_dir || return 1
    dump_ext4_path "$outer" /guest/rootfs-x86_64-debian.img "$after_dump" || return 1
    [[ $(sha256sum "$before_dump" | awk '{print $1}') == $(sha256sum "$after_dump" | awk '{print $1}') ]] || return 1
    debugfs -R 'stat /guest/linux/linux-qemu' "$outer" 2>/dev/null | grep -q '^Inode:' || return 1
    [[ $(rootfs_ext4_free_bytes "$outer") -ge $((2 * 1024 * 1024)) ]] || return 1
    [[ $(stat -c %y "$PLATFORM_IMAGES_DIR/linux/linux-qemu") == *.500000000* ]] || return 1
)
run_ok 'real ext4 platform injection normalizes private staging and preserves source timestamps' test_real_ext4_platform_injection

test_real_ext4_overlay_failure_rolls_back() (
    local fake_root="$work/rollback-root"
    local outer="$fake_root/IMAGES/rootfs/rootfs-aarch64-alpine.img"
    local seed="$work/rollback-seed"
    local before
    ROOT_DIR=$fake_root BUILD_DIR="$fake_root/build" ARCH=aarch64
    PLATFORM_IMAGES_DIR="$fake_root/IMAGES/qemu-aarch64"
    ROOTFS_BUILDERS=(alpine)
    QEMU_OUTER_FREE_SIZE=1M
    mkdir -p "$BUILD_DIR" "$PLATFORM_IMAGES_DIR/linux" "$(dirname -- "$outer")" "$seed/guest"
    printf kernel >"$PLATFORM_IMAGES_DIR/linux/linux-qemu"
    make_ext4 "$outer"
    printf nested >"$seed/guest/rootfs-aarch64-alpine.img"
    _rootfs_inject_tree_via_debugfs "$outer" "$seed"
    before=$(sha256sum "$outer" | awk '{print $1}')
    qemu_prepare_ivc_payloads() {
        local overlay="$BUILD_DIR/qemu-aarch64-ivc-rootfs-overlay"
        mkdir -p "$overlay/guest"
        printf collision >"$overlay/guest/linux"
    }
    qemu_ivc_validate_staged_payloads() { :; }
    ! (qemu_rootfs_inject_platform_dir)
    [[ $before == $(sha256sum "$outer" | awk '{print $1}') ]]
)
run_ok 'real ext4 outer image rolls back on Alpine IVC overlay semantic failure' test_real_ext4_overlay_failure_rolls_back

test_help() {
    local output
    output=$(bash "$repo_root/build.sh" help)
    [[ $output == *'--outer-tests'* && $output == *'--guest-tests'* ]]
    output=$(bash "$repo_root/scripts/platform/qemu.sh" aarch64 --help)
    [[ $output == *'nested'* && $output == *'BusyBox initramfs'* && $output == *'--outer-free-size'* ]]
}
run_ok 'top-level and QEMU help document test composition options' test_help

printf '1..%s\n' "$tests"
