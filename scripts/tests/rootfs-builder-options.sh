#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
integration=0

usage() {
    cat <<'EOF'
Usage: scripts/tests/rootfs-builder-options.sh [--integration] [options]

Options:
  --integration             Run the real x86_64 BusyBox composition build
  --build-root DIR          Override ROOTFS_TEST_BUILD_ROOT for plugin caches/work
  --busybox-src-dir DIR     Override BUSYBOX_SRC_DIR for the BusyBox source cache
  -h, --help                Show this help

The default test run is fast and network-free. Integration mode may use Docker
and downloads unless ROOTFS_TEST_BUILD_ROOT and BUSYBOX_SRC_DIR point at caches.
The equivalent environment-variable overrides are also supported.
EOF
}

while (($#)); do
    case $1 in
    --integration) integration=1; shift ;;
    --build-root)
        (($# >= 2)) || { printf 'missing value for --build-root\n' >&2; exit 2; }
        ROOTFS_TEST_BUILD_ROOT=$2
        export ROOTFS_TEST_BUILD_ROOT
        shift 2
        ;;
    --busybox-src-dir)
        (($# >= 2)) || { printf 'missing value for --busybox-src-dir\n' >&2; exit 2; }
        BUSYBOX_SRC_DIR=$2
        export BUSYBOX_SRC_DIR
        shift 2
        ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

work=$(mktemp -d /tmp/rootfs-builder-options.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

tests=0
fail() { printf 'not ok %s - %s\n' "$tests" "$*" >&2; exit 1; }
pass() { printf 'ok %s - %s\n' "$tests" "$*"; }
run_ok() {
    local message=$1
    shift
    tests=$((tests + 1))
    if ! "$@" >"$work/stdout" 2>"$work/stderr"; then
        sed -n '1,120p' "$work/stderr" >&2
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
assert_eq() { [[ $1 == "$2" ]] || fail "$3 (expected '$1', got '$2')"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "$3 (missing '$2')"; }

source_builder() {
    source "$repo_root/scripts/rootfs/$1.sh"
}

test_harness_cli() {
    local output
    output=$(bash "$repo_root/scripts/tests/rootfs-builder-options.sh" --help)
    [[ $output == *'Usage:'* && $output == *'--integration'* ]]
    ! bash "$repo_root/scripts/tests/rootfs-builder-options.sh" --unknown >/dev/null 2>&1
    ! bash "$repo_root/scripts/tests/rootfs-builder-options.sh" --build-root >/dev/null 2>&1
    ! bash "$repo_root/scripts/tests/rootfs-builder-options.sh" --busybox-src-dir >/dev/null 2>&1
}
run_ok 'test harness documents integration mode and rejects unknown arguments' test_harness_cli

test_help_options() {
    local builder output option
    for builder in busybox alpine debian; do
        output=$(bash "$repo_root/scripts/rootfs/$builder.sh" --help)
        for option in --outer-tests --guest-tests --guest-free-size --outer-free-size; do
            [[ $output == *"$option"* ]] || return 1
        done
    done
}
run_ok 'all builder help documents composition options' test_help_options

test_parse_options() (
    source_builder busybox
    mkfs_parse_args --outer-tests none --guest-tests cyclictest --guest-free-size 12M --outer-free-size 34M --guest /payload
    [[ $MKFS_OUTER_TESTS == none && $MKFS_GUEST_TESTS == cyclictest ]]
    [[ $MKFS_GUEST_FREE_SIZE == 12M && $MKFS_OUTER_FREE_SIZE == 34M && $MKFS_GUEST_DIR == /payload ]]
)
run_ok 'BusyBox parses composition options and existing guest option' test_parse_options

test_alpine_parse_options() (
    source_builder alpine
    alpine_parse_args --outer-tests ltp --guest-tests iozone --guest-free-size 1G --outer-free-size 2G --guest /payload
    [[ $ALPINE_OUTER_TESTS == ltp && $ALPINE_GUEST_TESTS == iozone ]]
    [[ $ALPINE_GUEST_FREE_SIZE == 1G && $ALPINE_OUTER_FREE_SIZE == 2G && $ALPINE_GUEST_DIR == /payload ]]
)
run_ok 'Alpine parses composition options and existing guest option' test_alpine_parse_options

test_debian_parse_options() (
    source_builder debian
    debian_parse_args --outer-tests none --guest-tests lmbench --guest-free-size 3M --outer-free-size 4M --guest /payload
    [[ $DEBIAN_OUTER_TESTS == none && $DEBIAN_GUEST_TESTS == lmbench ]]
    [[ $DEBIAN_GUEST_FREE_SIZE == 3M && $DEBIAN_OUTER_FREE_SIZE == 4M && $DEBIAN_GUEST_DIR == /payload ]]
)
run_ok 'Debian parses composition options and existing guest option' test_debian_parse_options

test_missing_value() {
    local builder
    for builder in busybox alpine debian; do
        if bash "$repo_root/scripts/rootfs/$builder.sh" x86_64 --outer-tests >"$work/missing.out" 2>"$work/missing.err"; then
            return 1
        fi
    done
}
run_ok 'all builders reject missing option values before building' test_missing_value

test_defaults() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    ROOTFS_TEST_BUILD="$repo_root/scripts/rootfs-tests/build.sh"
    rootfs_builder_load_test_options busybox A B C D
    [[ $A == none && $B == cyclictest,lmbench,iozone && $C == 256M && $D == 256M ]]
    rootfs_builder_load_test_options alpine E F G H
    [[ $E == ltp && $F == cyclictest,lmbench,iozone && $G == 256M && $H == 256M ]]
    rootfs_builder_load_test_options debian I J K L
    [[ $I == none && $J == cyclictest,lmbench,iozone && $K == 256M && $L == 256M ]]
)
run_ok 'common defaults come from plugin framework with 256M reserves' test_defaults

test_invalid_size() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    rootfs_builder_validate_reserves 12wat 256M
)
run_fail 'common preparation rejects invalid reserve syntax' test_invalid_size

test_preparation_calls() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    mkdir "$work/prep"
    ROOTFS_TEST_BUILD="$work/fake-build"
    ROOTFS_TEST_CALL_LOG="$work/calls"
    export ROOTFS_TEST_CALL_LOG
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$*" >>"$ROOTFS_TEST_CALL_LOG"' 'if [[ $1 == list ]]; then printf "%s\\n" ltp cyclictest lmbench iozone; fi' 'if [[ $1 == build ]]; then while (($#)); do [[ $1 != --output ]] || { mkdir -p "$2/fractional"; touch -d @1700000000.5 "$2" "$2/fractional"; break; }; shift; done; fi' >"$ROOTFS_TEST_BUILD"
    chmod +x "$ROOTFS_TEST_BUILD"
    rootfs_builder_prepare_test_overlays x86_64 alpine ltp cyclictest,lmbench,iozone "$work/prep" OUTER GUEST
    [[ -d $OUTER && -d $GUEST ]]
    [[ $(stat -c %y "$OUTER") == *.000000000* && $(stat -c %y "$GUEST") == *.000000000* ]] || return 1
    [[ $(stat -c %y "$OUTER/fractional") == *.000000000* && $(stat -c %y "$GUEST/fractional") == *.000000000* ]] || return 1
    grep -Fxq 'list --arch x86_64 --rootfs alpine --scope outer' "$ROOTFS_TEST_CALL_LOG"
    grep -Fxq "build --arch x86_64 --rootfs alpine --scope outer --tests ltp --output $OUTER" "$ROOTFS_TEST_CALL_LOG"
    grep -Fxq "build --arch x86_64 --rootfs alpine --scope guest --tests cyclictest,lmbench,iozone --output $GUEST" "$ROOTFS_TEST_CALL_LOG"
)
run_ok 'common preparation preflights and builds isolated scope overlays' test_preparation_calls

test_preparation_validation_cleanup() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    local parent="$work/prep-clean"
    mkdir "$parent"
    ROOTFS_TEST_BUILD="$work/invalid-overlay-build"
    printf '%s\n' '#!/usr/bin/env bash' \
        'if [[ $1 == list ]]; then printf "%s\\n" bad; exit; fi' \
        'while (($#)); do if [[ $1 == --output ]]; then mkfifo "$2/special"; exit; fi; shift; done' >"$ROOTFS_TEST_BUILD"
    chmod +x "$ROOTFS_TEST_BUILD"
    ! rootfs_builder_prepare_test_overlays x86_64 busybox bad bad "$parent" OUTER GUEST
    [[ -z $(find "$parent" -mindepth 1 -print -quit) ]]
)
run_ok 'common preparation removes both overlays when strict validation fails' test_preparation_validation_cleanup

test_incompatible_preflight() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    mkdir "$work/bad-prep"
    ROOTFS_TEST_BUILD="$work/incompatible-build"
    printf '%s\n' '#!/usr/bin/env bash' '[[ $1 != list ]] || exit 0' '[[ $1 != build ]] || { echo build-ran >"$ROOTFS_TEST_BUILD_MARKER"; exit 0; }' >"$ROOTFS_TEST_BUILD"
    chmod +x "$ROOTFS_TEST_BUILD"
    ROOTFS_TEST_BUILD_MARKER="$work/build-ran"
    export ROOTFS_TEST_BUILD_MARKER
    ! rootfs_builder_prepare_test_overlays x86_64 busybox ltp none "$work/bad-prep" OUTER GUEST
    [[ ! -e $ROOTFS_TEST_BUILD_MARKER ]]
)
run_ok 'plugin incompatibility fails before any plugin build' test_incompatible_preflight

test_clean_scope() (
    local output="$work/clean"
    mkdir -p "$output"
    touch "$output/rootfs-x86_64-busybox.img" "$output/rootfs-x86_64-busybox.img.base.tmp.1"
    touch "$output/rootfs-x86_64-busybox.img.base.tmp.1.lock"
    touch "$output/initramfs-x86_64-busybox.cpio.gz" "$output/initramfs-x86_64-busybox.cpio.gz.tmp.1"
    touch "$output/rootfs-x86_64-alpine.img" "$output/rootfs-x86_64-alpine.img.base.tmp.1"
    touch "$output/rootfs-x86_64-alpine.img.base.tmp.1.lock"
    touch "$output/rootfs-x86_64-debian.img" "$output/rootfs-x86_64-debian.img.base.tmp.1"
    touch "$output/rootfs-x86_64-debian.img.base.tmp.1.lock"
    touch "$output/unrelated.tmp.1"
    source_builder busybox
    MKFS_OUT_DIR=$output
    mkfs_clean_outputs
    source_builder alpine
    ALPINE_OUT_DIR=$output
    alpine_clean_outputs
    source_builder debian
    DEBIAN_OUT_DIR=$output
    DEBIAN_OUTPUT=
    debian_clean_outputs
    [[ -e $output/unrelated.tmp.1 ]]
    [[ $(find "$output" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]
)
run_ok 'clean removes finals and builder-owned temporaries but preserves unrelated files' test_clean_scope

test_real_tiny_composition() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    local area="$work/real" base="$work/real/base.img" final="$work/real/final.img"
    mkdir -p "$area" "$area/empty-guest"
    ROOTFS_TEST_BUILD="$work/tiny-build"
    printf '%s\n' '#!/usr/bin/env bash' \
        'if [[ $1 == list ]]; then printf "%s\\n" marker; exit; fi' \
        'while (($#)); do case $1 in --scope) scope=$2; shift 2;; --output) output=$2; shift 2;; *) shift;; esac; done' \
        'mkdir -p "$output/${scope}-marker"' \
        'printf "%s\\n" "$scope" >"$output/${scope}-marker/payload"' \
        'find "$output" -depth -exec touch -d @1700000000 {} +' >"$ROOTFS_TEST_BUILD"
    chmod +x "$ROOTFS_TEST_BUILD"
    rootfs_builder_prepare_test_overlays x86_64 busybox marker marker "$area" OUTER GUEST
    truncate -s 32M "$base"
    mkfs.ext4 -q -F "$base"
    touch -d @1700000000 "$area/empty-guest" "$base"
    rootfs_compose_test_images "$base" "$OUTER" "$GUEST" "$area/empty-guest" \
        x86_64 busybox 1M 1M "$final"
    debugfs -R 'stat /outer-marker/payload' "$final" >/dev/null 2>&1
    debugfs -R 'dump /guest/rootfs-x86_64-busybox.img /dev/null' "$final" >/dev/null 2>&1
)
run_ok 'common preparation feeds a real tiny ext4 composition' test_real_tiny_composition

test_busybox_real_pack_boundary() (
    source_builder busybox
    local output="$work/busybox-pack" guest="$work/busybox-guest" before
    mkdir -p "$output" "$guest"
    printf legacy >"$guest/payload"
    MKFS_ARCH=x86_64
    MKFS_OUT_DIR=$output
    MKFS_GUEST_DIR=$guest
    MKFS_OUTER_GUEST_DIR=$guest
    MKFS_OUTER_TEST_OVERLAY="$work/outer-overlay"
    MKFS_GUEST_TEST_OVERLAY="$work/guest-overlay"
    MKFS_GUEST_FREE_SIZE=256M
    MKFS_OUTER_FREE_SIZE=256M
    mkdir -p "$MKFS_OUTER_TEST_OVERLAY" "$MKFS_GUEST_TEST_OVERLAY"
    rootfs_compose_test_images() {
        [[ $# -eq 9 ]] || return 1
        [[ $1 == "$output/rootfs-x86_64-busybox.img.base.tmp."* ]]
        [[ $2 == "$MKFS_OUTER_TEST_OVERLAY" && $3 == "$MKFS_GUEST_TEST_OVERLAY" ]]
        [[ $4 == "$guest" && $5 == x86_64 && $6 == busybox && $7 == 256M && $8 == 256M ]]
        ! debugfs -R 'stat /guest/payload' "$1" 2>&1 | grep -q '^Inode:'
        local spec path expected
        for spec in 'console 5 1' 'null 1 3' 'zero 1 5' 'tty 5 0' 'ttyS0 4 64'; do
            read -r path expected_major expected_minor <<<"$spec"
            expected=$(printf '%02x:%02x' "$expected_major" "$expected_minor")
            debugfs -R "stat /dev/$path" "$1" 2>&1 | grep -q 'Type: character' || return 1
            debugfs -R "stat /dev/$path" "$1" 2>&1 | grep -qi "(hex $expected)" || return 1
            debugfs -R "stat /dev/$path" "$1" 2>&1 | grep -Eq 'Mode:  +0600' || return 1
            debugfs -R "stat /dev/$path" "$1" 2>&1 | grep -Eq 'User: +0 +Group: +0' || return 1
        done
        sha256sum "$output/initramfs-x86_64-busybox.cpio.gz" | awk '{print $1}' >"$work/cpio-before"
        touch "$1.lock"
        cp -- "$1" "$9"
    }
    mkfs_pack_fs
    before=$(<"$work/cpio-before")
    [[ $before == "$(sha256sum "$output/initramfs-x86_64-busybox.cpio.gz" | awk '{print $1}')" ]]
    gzip -dc "$output/initramfs-x86_64-busybox.cpio.gz" | cpio -it 2>/dev/null | grep -q 'guest/payload$'
    local listing spec device major minor
    listing=$(gzip -dc "$output/initramfs-x86_64-busybox.cpio.gz" | cpio -itv 2>/dev/null)
    for spec in 'console 5 1' 'null 1 3' 'zero 1 5' 'tty 5 0' 'ttyS0 4 64'; do
        read -r device major minor <<<"$spec"
        grep -Eq "^c[rwx-]{9} +[0-9]+ +[^ ]+ +[^ ]+ +$major, +$minor .*dev/$device$" <<<"$listing" || return 1
    done
    mkdir "$work/cpio-extract"
    fakeroot bash -c 'cd "$1"; gzip -dc "$2" | cpio -idmu --quiet; stat -c "%F %t:%T %a %u:%g" dev/console' \
        bash "$work/cpio-extract" "$output/initramfs-x86_64-busybox.cpio.gz" >"$work/cpio-device-stat"
    grep -Fxq 'character special file 5:1 600 0:0' "$work/cpio-device-stat"
    ! find "$output" -maxdepth 1 -name '*.base.tmp.*' -print -quit | grep -q .
)
run_ok 'BusyBox real pack keeps cpio stable and clean base uncontaminated across composition' test_busybox_real_pack_boundary

test_full_guest_validation_precedes_build() (
    source_builder busybox
    local guest="$work/invalid-guest"
    mkdir "$guest"
    printf bad >"$guest/fractional"
    touch -d @1700000000.5 "$guest/fractional"
    MKFS_ARCH=x86_64
    MKFS_GUEST_DIR=$guest
    rootfs_builder_prepare_test_overlays() { touch "$work/plugin-started"; }
    clone_repository() { touch "$work/base-started"; }
    ! mkfs
    [[ ! -e $work/plugin-started && ! -e $work/base-started ]]
    [[ $(stat -c %y "$guest/fractional") == *.500000000* ]]
)
run_ok 'full guest validation is read-only and precedes plugin/base work' test_full_guest_validation_precedes_build

test_debian_canonical_output_mount() (
    source_builder debian
    local relative="relative output/with apostrophe's spaces" expected
    mkdir -p "$work/$relative"
    cd "$work"
    DEBIAN_ARCH=x86_64
    DEBIAN_OUT_DIR=$relative
    debian_init_config
    expected="$work/$relative/rootfs-x86_64-debian.img"
    [[ $DEBIAN_ROOTFS_IMG == "$expected" ]]
    [[ $(debian_output_mount_arg) == "type=bind,src=$work/$relative,dst=/output" ]]
    DEBIAN_DOCKER_IMAGE=debian:test
    DEBIAN_IMG_SIZE=1M
    docker() { printf '%s\n' "$@" >"$work/debian-docker-args"; }
    debian_pack_rootfs_volume volume-name "$DEBIAN_ROOTFS_IMG.base.tmp.1"
    grep -Fxq -- '--mount' "$work/debian-docker-args"
    grep -Fxq -- "type=bind,src=$work/$relative,dst=/output" "$work/debian-docker-args"
    grep -Fxq -- 'volume-name:/rootfs:ro' "$work/debian-docker-args"
    grep -Fxq -- "$(basename "$DEBIAN_ROOTFS_IMG.base.tmp.1")" "$work/debian-docker-args"
    ! grep -F "$(basename "$DEBIAN_ROOTFS_IMG.base.tmp.1")" "$work/debian-docker-args" |
        grep -Fq 'dd if='
)
run_ok 'Debian canonicalizes relative space-containing output for --mount' test_debian_canonical_output_mount

test_busybox_pair_rollback() (
    source_builder busybox
    local area="$work/pair" fail_at count init_final image_final init_candidate image_candidate
    mkdir "$area"
    for fail_at in 1 2 3 4; do
        init_final="$area/init"; image_final="$area/image"
        init_candidate="$area/init.new"; image_candidate="$area/image.new"
        printf old-init >"$init_final"; printf old-image >"$image_final"
        printf new-init >"$init_candidate"; printf new-image >"$image_candidate"
        count=0
        mv() {
            count=$((count + 1))
            ((count != fail_at)) || return 71
            command mv "$@"
        }
        ! mkfs_publish_pair "$init_candidate" "$init_final" "$image_candidate" "$image_final"
        [[ $(<"$init_final") == old-init && $(<"$image_final") == old-image ]] || return 1
    done
    unset -f mv
    printf new-init >"$init_candidate"; printf new-image >"$image_candidate"
    mkfs_publish_pair "$init_candidate" "$init_final" "$image_candidate" "$image_final"
    [[ $(<"$init_final") == new-init && $(<"$image_final") == new-image ]]
)
run_ok 'BusyBox pair publication rolls both finals back at every rename boundary' test_busybox_pair_rollback

test_busybox_pair_post_rename_signal_status() (
    source_builder busybox
    local area="$work/pair-post-rename" fail_at count reported init_state image_state
    mkdir "$area"
    for reported in 130 143; do
        for fail_at in 1 2 3 4; do
            printf old-init >"$area/init"; printf old-image >"$area/image"
            printf new-init >"$area/init.new"; printf new-image >"$area/image.new"
            count=0
            mv() {
                count=$((count + 1))
                command mv "$@" || return $?
                ((count != fail_at)) || return "$reported"
            }
            ! mkfs_publish_pair "$area/init.new" "$area/init" "$area/image.new" "$area/image"
            [[ -f $area/init && -f $area/image ]] || return 1
            init_state=$(<"$area/init"); image_state=$(<"$area/image")
            [[ $init_state == old-init && $image_state == old-image ||
               $init_state == new-init && $image_state == new-image ]] || return 1
        done
    done
)
run_ok 'BusyBox pair survives mv post-rename 130/143 results without a mixed or missing pair' test_busybox_pair_post_rename_signal_status

test_busybox_pair_defers_signals() (
    source_builder busybox
    local area="$work/pair-signals" signal point count status init_state image_state
    mkdir "$area"
    for signal in INT TERM; do
        for point in $(seq 1 12); do
            printf old-init >"$area/init"; printf old-image >"$area/image"
            printf new-init >"$area/init.new"; printf new-image >"$area/image.new"
            count=0
            mkfs_pair_checkpoint() {
                count=$((count + 1))
                if ((count == point)); then kill -s "$signal" "$BASHPID"; fi
            }
            set +e
            mkfs_publish_pair "$area/init.new" "$area/init" "$area/image.new" "$area/image"
            status=$?
            set -e
            [[ $signal == INT && $status -eq 130 || $signal == TERM && $status -eq 143 ]] || return 1
            init_state=$(<"$area/init"); image_state=$(<"$area/image")
            [[ $init_state == old-init && $image_state == old-image ||
               $init_state == new-init && $image_state == new-image ]] || return 1
        done
    done
)
run_ok 'BusyBox pair publication defers INT/TERM at every critical checkpoint' test_busybox_pair_defers_signals

test_busybox_compose_failure_preserves_pair() (
    source_builder busybox
    local output="$work/compose-failure" guest="$work/compose-failure-guest"
    mkdir "$output" "$guest" "$work/compose-failure-outer" "$work/compose-failure-tests"
    printf old-init >"$output/initramfs-x86_64-busybox.cpio.gz"
    printf old-image >"$output/rootfs-x86_64-busybox.img"
    MKFS_ARCH=x86_64 MKFS_OUT_DIR=$output MKFS_GUEST_DIR=$guest MKFS_OUTER_GUEST_DIR=$guest
    MKFS_OUTER_TEST_OVERLAY="$work/compose-failure-outer"
    MKFS_GUEST_TEST_OVERLAY="$work/compose-failure-tests"
    MKFS_GUEST_FREE_SIZE=1M MKFS_OUTER_FREE_SIZE=1M
    rootfs_compose_test_images() { return 72; }
    ! mkfs_pack_fs
    [[ $(<"$output/initramfs-x86_64-busybox.cpio.gz") == old-init ]]
    [[ $(<"$output/rootfs-x86_64-busybox.img") == old-image ]]
)
run_ok 'BusyBox compose failure preserves both previously published files' test_busybox_compose_failure_preserves_pair

test_strict_guest_metadata_classes() (
    source "$repo_root/scripts/lib/rootfs-compose.sh"
    local guest="$work/strict-guest" before
    mkdir "$guest"
    printf bad >"$guest/bad"
    touch -d @1700000000.5 "$guest/bad"
    ! rootfs_validate_payload_tree "$guest"
    [[ $(stat -c %y "$guest/bad") == *.500000000* ]]
    rm "$guest/bad"
    printf bad >"$guest/bad\"name"
    touch -d @1700000000 "$guest/bad\"name"
    ! rootfs_validate_payload_tree "$guest"
    rm "$guest/bad\"name"
    mkfifo "$guest/fifo"
    touch -d @1700000000 "$guest/fifo"
    ! rootfs_validate_payload_tree "$guest"
    rm "$guest/fifo"
    printf bad >"$guest/metadata"
    touch -d @1700000000 "$guest/metadata"
    if setfattr -n user.rootfs-test -v bad "$guest/metadata" 2>/dev/null; then
        ! rootfs_validate_payload_tree "$guest"
        setfattr -x user.rootfs-test "$guest/metadata"
    fi
    if setfacl -m u:daemon:r "$guest/metadata" 2>/dev/null; then
        ! rootfs_validate_payload_tree "$guest"
        setfacl -b "$guest/metadata"
    fi
)
run_ok 'strict guest validator rejects fractional, unsafe, special, xattr, and ACL payloads' test_strict_guest_metadata_classes

test_guest_inventory_producer_failures() (
    source_builder busybox
    local guest="$work/find-failure-guest" marker="$work/find-expensive-started" mode
    mkdir "$guest" "$work/inventory-temps"
    printf valid >"$guest/valid"
    touch -d @1700000000 "$guest/valid"
    for mode in immediate partial; do
        find() {
            [[ $mode != partial ]] || printf '%s\0' "$guest/valid"
            return 74
        }
        TMPDIR="$work/inventory-temps"
        export TMPDIR
        ! rootfs_validate_payload_tree "$guest"
        MKFS_ARCH=x86_64 MKFS_GUEST_DIR=$guest
        rootfs_builder_prepare_test_overlays() { touch "$marker"; }
        mkfs_prepare_busybox_source() { touch "$marker"; }
        ! mkfs
        [[ ! -e $marker ]]
        [[ -z $(command find "$work/inventory-temps" -mindepth 1 -print -quit) ]]
    done
    unset -f find
)
run_ok 'guest validation rejects immediate and partial inventory producer failures without leaks' test_guest_inventory_producer_failures

test_ext4_device_semantic_noop() (
    source_builder busybox
    local image="$work/device-noop.img"
    truncate -s 8M "$image"
    mkfs.ext4 -q -F "$image"
    debugfs() { return 0; }
    ! mkfs_add_ext4_devices "$image"
)
run_ok 'BusyBox device creation rejects a debugfs semantic no-op that exits zero' test_ext4_device_semantic_noop

test_busybox_source_preparation_serializes() (
    source_builder busybox
    local area="$work/source-lock" state="$work/source-state" overlap="$work/source-overlap"
    mkdir -p "$area/cache"
    printf source >"$area/cache/README"
    BUSYBOX_SRC_DIR="$area/cache"
    BUSYBOX_PATCH_DIR="$area/patches"
    mkdir "$BUSYBOX_PATCH_DIR"
    clone_repository() { :; }
    checkout_ref() {
        if ! mkdir "$state" 2>/dev/null; then touch "$overlap"; return 1; fi
        sleep 0.2
        rmdir "$state"
    }
    apply_patches() { :; }
    (composition_dir="$area/run-one"; mkdir "$composition_dir"; mkfs_prepare_busybox_source) &
    local first=$!
    (composition_dir="$area/run-two"; mkdir "$composition_dir"; mkfs_prepare_busybox_source) &
    local second=$!
    wait "$first" && wait "$second"
    [[ ! -e $overlap && -f $area/run-one/busybox-source/README && -f $area/run-two/busybox-source/README ]]
)
run_ok 'BusyBox cache preparation serializes and produces per-run source copies' test_busybox_source_preparation_serializes

test_alpine_archive_atomic_cache() (
    source_builder alpine
    local area="$work/alpine-cache" good=archive-content sha state="$work/alpine-download-state" overlap="$work/alpine-overlap"
    mkdir "$area"
    ALPINE_ARCHIVE="$area/minirootfs.tar.gz"
    ALPINE_METADATA_FILE=minirootfs.tar.gz
    ALPINE_METADATA_SHA256=$(printf %s "$good" | sha256sum | awk '{print $1}')
    ALPINE_METADATA_ARCH=x86_64 ALPINE_METADATA_VERSION=test ALPINE_METADATA_DATE=test ALPINE_METADATA_TIME=test ALPINE_METADATA_SIZE=${#good}
    ALPINE_URL=https://invalid.example
    printf corrupt >"$ALPINE_ARCHIVE"
    curl() {
        local output
        while (($#)); do [[ $1 != -o ]] || { output=$2; break; }; shift; done
        if ! mkdir "$state" 2>/dev/null; then touch "$overlap"; fi
        sleep 0.2
        printf %s "$good" >"$output"
        rmdir "$state" 2>/dev/null || true
    }
    alpine_download_archive
    [[ $(<"$ALPINE_ARCHIVE") == "$good" ]]
    printf corrupt >"$ALPINE_ARCHIVE"
    (alpine_download_archive) & local first=$!
    (alpine_download_archive) & local second=$!
    wait "$first" && wait "$second"
    [[ ! -e $overlap && $(<"$ALPINE_ARCHIVE") == "$good" ]]
    ! find "$area" -name '*.tmp.*' -print -quit | grep -q .
)
run_ok 'Alpine archive cache replaces corruption and serializes atomic download publication' test_alpine_archive_atomic_cache

test_alpine_archive_interruption_preserves_cache() (
    source_builder alpine
    local area="$work/alpine-interrupt"
    mkdir "$area"
    ALPINE_ARCHIVE="$area/minirootfs.tar.gz"
    ALPINE_METADATA_FILE=minirootfs.tar.gz
    ALPINE_METADATA_SHA256=$(printf good | sha256sum | awk '{print $1}')
    ALPINE_METADATA_ARCH=x86_64 ALPINE_METADATA_VERSION=test ALPINE_METADATA_DATE=test ALPINE_METADATA_TIME=test ALPINE_METADATA_SIZE=4
    ALPINE_URL=https://invalid.example
    printf prior-corrupt >"$ALPINE_ARCHIVE"
    curl() {
        local output
        while (($#)); do [[ $1 != -o ]] || { output=$2; break; }; shift; done
        printf partial >"$output"
        return 70
    }
    ! alpine_download_archive
    [[ $(<"$ALPINE_ARCHIVE") == prior-corrupt ]]
    ! find "$area" -name '*.tmp.*' -print -quit | grep -q .
)
run_ok 'interrupted Alpine download preserves cache and removes adjacent temporary' test_alpine_archive_interruption_preserves_cache

test_alpine_ltp_legacy_environment() (
    source_builder alpine
    ! (ALPINE_LTP_PREFIX=/custom; alpine_validate_legacy_ltp_environment)
    ! (ALPINE_LTP_PREFIX=/opt/ltp; ALPINE_LTP_DOCKER_IMAGE=legacy; alpine_validate_legacy_ltp_environment)
    ! (ALPINE_LTP_DOCKER_IMAGE=; ALPINE_LTP_DOCKER_INSTALL_PACKAGES=1; alpine_validate_legacy_ltp_environment)
    ALPINE_LTP_PREFIX=/opt/ltp ALPINE_LTP_DOCKER_IMAGE=
    ALPINE_LTP_DOCKER_INSTALL_PACKAGES=0
    alpine_validate_legacy_ltp_environment
)
run_ok 'Alpine explicitly rejects unsupported legacy LTP overrides before work' test_alpine_ltp_legacy_environment

has_ext4_path() {
    local output
    output=$(debugfs -R "stat $2" "$1" 2>&1) || return 1
    grep -q '^Inode:' <<<"$output"
}

if ((integration)); then
    integration_dir="$work/integration"
    output_dir="$integration_dir/output"
    nested_image="$integration_dir/nested-rootfs-x86_64-busybox.img"
    initramfs_tree="$integration_dir/initramfs"
    mkdir -p "$output_dir" "$initramfs_tree"

    run_ok 'integration builds x86_64 BusyBox with requested test composition' \
        bash "$repo_root/scripts/rootfs/busybox.sh" x86_64 \
            --out_dir "$output_dir" \
            --outer-tests none \
            --guest-tests cyclictest,lmbench,iozone \
            --guest-free-size 256M \
            --outer-free-size 256M

    outer_image="$output_dir/rootfs-x86_64-busybox.img"
    initramfs="$output_dir/initramfs-x86_64-busybox.cpio.gz"
    run_ok 'integration outer ext4 is clean' e2fsck -fn "$outer_image"
    run_ok 'integration outer contains nested image' \
        has_ext4_path "$outer_image" /guest/rootfs-x86_64-busybox.img
    run_fail 'integration outer excludes root guest-tests' \
        has_ext4_path "$outer_image" /guest-tests
    run_ok 'integration dumps nested ext4 image' \
        debugfs -R "dump /guest/rootfs-x86_64-busybox.img $nested_image" "$outer_image"
    run_ok 'integration nested ext4 is clean' e2fsck -fn "$nested_image"
    run_ok 'integration nested contains cyclictest executable' \
        has_ext4_path "$nested_image" /guest-tests/cyclictest/cyclictest
    run_ok 'integration nested contains lmbench bin/Linux launcher layout' \
        has_ext4_path "$nested_image" /guest-tests/lmbench/bin/Linux/lmbench
    run_ok 'integration nested contains lmbench scripts layout' \
        has_ext4_path "$nested_image" /guest-tests/lmbench/scripts/lmbench
    run_ok 'integration nested contains iozone executable' \
        has_ext4_path "$nested_image" /guest-tests/iozone/iozone

    unpack_initramfs() (
        fakeroot bash -c 'cd "$1"; gzip -dc "$2" | cpio -idmu --quiet' \
            bash "$initramfs_tree" "$initramfs"
    )
    run_ok 'integration unpacks BusyBox initramfs' unpack_initramfs
    run_fail 'integration initramfs excludes guest-tests' test -e "$initramfs_tree/guest-tests"
    run_fail 'integration initramfs excludes nested image' \
        test -e "$initramfs_tree/guest/rootfs-x86_64-busybox.img"

    source "$repo_root/scripts/lib/rootfs-compose.sh"
    reserve_bytes=$(rootfs_parse_size_bytes 256M)
    run_ok 'integration outer retains at least 256M free' \
        test "$(rootfs_ext4_free_bytes "$outer_image")" -ge "$reserve_bytes"
    run_ok 'integration nested retains at least 256M free' \
        test "$(rootfs_ext4_free_bytes "$nested_image")" -ge "$reserve_bytes"
fi

printf '1..%s\n' "$tests"
