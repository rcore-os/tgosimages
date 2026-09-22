#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
work=$(mktemp -d /tmp/orangepi-rootfs-flow.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

# shellcheck source=/dev/null
source "$repo_root/scripts/platform/orangepi-5-plus.sh"
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/rootfs-compose.sh"

info() { :; }
success() { :; }
warn() { printf 'warning: %s\n' "$*" >&2; }

tests=0
fail() { printf 'not ok %s - %s\n' "$tests" "$*" >&2; exit 1; }
pass() { printf 'ok %s - %s\n' "$tests" "$*"; }
run_ok() {
    local message=$1
    shift
    tests=$((tests + 1))
    if ! "$@" >"$work/stdout" 2>"$work/stderr"; then
        sed -n '1,100p' "$work/stderr" >&2
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

test_chosen_overlay() {
    local dtbo="$work/chosen.dtbo"
    orangepi_compile_chosen_overlay \
        "$repo_root/patches/orangepi/orangepi-5-plus-chosen-overlay.dts" "$dtbo"
    [[ -s $dtbo ]]
}
run_ok 'chosen overlay compiles without its fragment false positive' test_chosen_overlay

test_source_cache_ignores_framework_patch_metadata_only() (
    local repository="$work/orangepi-source-cache" patch_dir="$work/orangepi-source-patches"
    mkdir -p "$repository" "$patch_dir"
    git -C "$repository" init -q
    git -C "$repository" config user.name test
    git -C "$repository" config user.email test@example.com
    git -C "$repository" config core.excludesFile /dev/null
    printf source >"$repository/source"
    git -C "$repository" add source
    git -C "$repository" commit -qm base
    LINUX_REF=$(git -C "$repository" rev-parse HEAD)
    LINUX_PATCH_DIR=$patch_dir
    mkdir -p "$repository/.patch_stamps"
    printf identity >"$repository/.patch_stamps/patch-set.sha256"

    orangepi_configure_source_excludes "$repository"
    orangepi_assert_safe_source_tree "$repository" || return 1

    printf user >"$repository/user-file"
    ! orangepi_assert_safe_source_tree "$repository"
)
run_ok 'Orange Pi source safety ignores framework patch metadata but rejects user files' \
    test_source_cache_ignores_framework_patch_metadata_only

# Exercise the real archive-to-ext4 path with small local benchmark fixtures.
fixture_tree="$work/rootfs-fixture"
fixture_archive="$work/jammy-minimal-arm64.fixture.tar.lz4"
fixture_image_dir="$work/formal-rootfs-images"
fixture_output="$fixture_image_dir/rootfs-fixture.img"
fixture_wrapper="$work/fixture-wrapper"
fixture_mktemp_log="$work/fixture-mktemp.log"
mkdir "$fixture_image_dir" "$fixture_wrapper"
real_mktemp=$(command -v mktemp)
cat >"$fixture_wrapper/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MKTEMP_LOG"
exec "$REAL_MKTEMP" "$@"
MKTEMP
chmod +x "$fixture_wrapper/mktemp"
mkdir -p "$fixture_tree/etc"
printf orangepi-jammy >"$fixture_tree/etc/rootfs-marker"
FAKEROOTDONTTRYCHOWN=1 fakeroot -- bash -euo pipefail -c \
    'chown 123:456 "$1/etc/rootfs-marker"; tar -cpf - --xattrs -C "$1" . | lz4 -q - "$2"' \
    _ "$fixture_tree" "$fixture_archive"
BUILD_DIR="$work/fixture-build"
ORANGEPI_GUEST_FREE_SIZE=8M
rootfs_builder_prepare_test_overlays() {
    local parent=$5 outer_var=$6 guest_var=$7
    mkdir -p "$parent/outer" "$parent/guest/guest-tests/cyclictest" \
        "$parent/guest/guest-tests/lmbench/bin/Linux" \
        "$parent/guest/guest-tests/iozone"
    printf cyclic >"$parent/guest/guest-tests/cyclictest/cyclictest"
    printf lmbench >"$parent/guest/guest-tests/lmbench/bin/Linux/lat_syscall"
    printf iozone >"$parent/guest/guest-tests/iozone/iozone"
    find "$parent" -exec touch -h -d @0 {} +
    printf -v "$outer_var" '%s' "$parent/outer"
    printf -v "$guest_var" '%s' "$parent/guest"
}
run_ok 'Orange Pi archive becomes a benchmark guest ext4' \
    env PATH="$fixture_wrapper:$PATH" MKTEMP_LOG="$fixture_mktemp_log" \
        REAL_MKTEMP="$real_mktemp" bash -c '
            source "$1/scripts/platform/orangepi-5-plus.sh"
            source "$1/scripts/lib/rootfs-compose.sh"
            info() { :; }; success() { :; }; warn() { printf "warning: %s\n" "$*" >&2; }
            rootfs_builder_prepare_test_overlays() {
                local parent=$5 outer_var=$6 guest_var=$7
                mkdir -p "$parent/outer" "$parent/guest/guest-tests/cyclictest" \
                    "$parent/guest/guest-tests/lmbench/bin/Linux" "$parent/guest/guest-tests/iozone"
                printf cyclic >"$parent/guest/guest-tests/cyclictest/cyclictest"
                printf lmbench >"$parent/guest/guest-tests/lmbench/bin/Linux/lat_syscall"
                printf iozone >"$parent/guest/guest-tests/iozone/iozone"
                find "$parent" -exec touch -h -d @0 {} +
                printf -v "$outer_var" %s "$parent/outer"
                printf -v "$guest_var" %s "$parent/guest"
            }
            BUILD_DIR=$2 ORANGEPI_GUEST_FREE_SIZE=8M
            orangepi_build_guest_rootfs "$3" "$4"
        ' _ "$repo_root" "$BUILD_DIR" "$fixture_archive" "$fixture_output"
run_ok 'Orange Pi guest rootfs keeps publication temporaries out of the image directory' \
    bash -c '! grep -F -- "$1/" "$2"' _ "$fixture_image_dir" "$fixture_mktemp_log"
run_ok 'generated guest ext4 is clean' e2fsck -fn "$fixture_output"
assert_eq orangepi-jammy "$(debugfs -R 'cat /etc/rootfs-marker' "$fixture_output" 2>/dev/null)" \
    'guest rootfs retains upstream content'
debugfs -R 'stat /etc/rootfs-marker' "$fixture_output" 2>&1 | \
    grep -Eq 'User:[[:space:]]+123[[:space:]]+Group:[[:space:]]+456' || \
    fail 'guest rootfs lost archived ownership'
for path in \
    /guest-tests/cyclictest/cyclictest \
    /guest-tests/lmbench/bin/Linux/lat_syscall \
    /guest-tests/iozone/iozone; do
    debugfs -R "stat $path" "$fixture_output" 2>&1 | grep -q 'Inode:' || \
        fail "guest rootfs lacks $path"
done

# Verify the public command boundaries without invoking expensive upstream builds.
BUILD_DIR="$work/build"
LINUX_SRC_DIR="$BUILD_DIR/orangepi"
LINUX_PATCH_DIR="$work/patches"
PLATFORM_IMAGES_DIR="$work/platform-images"
PLATFORM_ROOTFS_DIR="$work/rootfs-images"
ORANGEPI_BASE_IMAGE="$BUILD_DIR/orangepi-rootfs/orangepi-5-plus-base.img"
ORANGEPI_GUEST_ROOTFS="$PLATFORM_ROOTFS_DIR/rootfs-aarch64-orangepi-jammy.img"
mkdir -p "$LINUX_SRC_DIR" "$LINUX_PATCH_DIR" "$PLATFORM_IMAGES_DIR" \
    "$PLATFORM_ROOTFS_DIR" "$(dirname -- "$ORANGEPI_BASE_IMAGE")"
call_log="$work/calls"

orangepi_prepare_source() {
    printf 'prepare\n' >>"$call_log"
    mkdir -p "$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/dts/rockchip"
    printf kernel >"$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/Image"
    printf dtb >"$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb"
}
orangepi_run_upstream() { printf 'upstream:%s\n' "$1" >>"$call_log"; }
copy_required() { mkdir -p "$(dirname -- "$2")"; cp "$1" "$2"; }

run_ok 'linux builds only the upstream kernel stage' linux
assert_eq $'prepare\nupstream:kernel' "$(cat "$call_log")" 'linux stage calls'
[[ -f $PLATFORM_IMAGES_DIR/linux/orangepi-5-plus &&
   -f $PLATFORM_IMAGES_DIR/linux/orangepi-5-plus.dtb ]] || fail 'linux outputs are incomplete'

: >"$call_log"
orangepi_select_rootfs_archive() { printf '%s\n' "$fixture_archive"; }
orangepi_build_guest_rootfs() {
    printf 'guest-rootfs:%s:%s\n' "$1" "$2" >>"$call_log"
    printf guest >"$2"
}
run_ok 'rootfs builds only the upstream rootfs stage and guest ext4' rootfs
assert_eq "prepare
upstream:rootfs
guest-rootfs:$fixture_archive:$ORANGEPI_GUEST_ROOTFS" \
    "$(cat "$call_log")" 'rootfs stage calls'

# Finalization consumes the explicit all payload set and nothing else.
for component in u-boot arceos starry zephyr freertos ivc unrelated; do
    mkdir -p "$PLATFORM_IMAGES_DIR/$component"
    printf payload >"$PLATFORM_IMAGES_DIR/$component/payload"
done
printf uboot >"$PLATFORM_IMAGES_DIR/u-boot/u-boot-orangepi5-spi.bin"
printf base >"$ORANGEPI_BASE_IMAGE"
rootfs_compose_disk_guest() {
    local component
    for component in linux u-boot arceos starry zephyr freertos ivc; do
        [[ -d $2/$component ]] || return 1
    done
    [[ ! -e $2/unrelated ]] || return 1
    cp "$1" "$8"
}
: >"$call_log"
run_ok 'finalization stages every all payload and excludes unrelated content' \
    finalize_linux_image

legacy_output="$PLATFORM_ROOTFS_DIR/orangepi-5-plus.img"
legacy_temp_lock="$PLATFORM_ROOTFS_DIR/.orangepi-5-plus.img.disk.legacy.lock"
: >"${legacy_output}.lock"
: >"${ORANGEPI_BASE_IMAGE}.lock"
: >"$legacy_temp_lock"
run_ok 'final image clean removes legacy adjacent lock files' orangepi_clean_final_image
[[ ! -e ${legacy_output}.lock && ! -e ${ORANGEPI_BASE_IMAGE}.lock &&
   ! -e $legacy_temp_lock ]] || fail 'final image clean retained legacy lock files'

: >"$call_log"
linux() { printf 'linux\n' >>"$call_log"; }
rootfs() { printf 'rootfs\n' >>"$call_log"; }
run_parallel_functions() { printf 'parallel:%s\n' "$*" >>"$call_log"; }
ivc() { printf 'ivc\n' >>"$call_log"; }
orangepi_build_base_image() { printf 'base-image\n' >>"$call_log"; }
finalize_linux_image() { printf 'finalize\n' >>"$call_log"; }
run_ok 'all builds every payload before publishing the final image' all
assert_eq $'linux\nrootfs\nparallel:all uboot arceos starry zephyr freertos --\nivc\nbase-image\nfinalize' \
    "$(cat "$call_log")" 'all build/finalize ordering'

run_fail 'the removed img subcommand is rejected' \
    bash "$repo_root/scripts/platform/orangepi-5-plus.sh" img

printf '1..%s\n' "$tests"
