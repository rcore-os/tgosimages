#!/usr/bin/env bash
set -euo pipefail
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
source "$repo_root/scripts/rootfs/busybox.sh"
export BUSYBOX_SRC_DIR="$work/source" BUSYBOX_BUILD_ROOT="$work/cache" BUSYBOX_PATCH_DIR="$work/patches"
export BUILD_LOG="$work/build.log" FAIL_BUILD="$work/fail" PATH="$work/bin:$PATH"
mkdir -p "$BUSYBOX_SRC_DIR" "$work/bin" "$BUSYBOX_PATCH_DIR"
cat > "$BUSYBOX_SRC_DIR/Makefile" <<'MAKE'
.PHONY: all distclean defconfig oldconfig
all:
	@mkdir .building || exit 1
	@sleep 0.1
	@echo build >> "$(BUILD_LOG)"
	@test -f input.o || { echo compile >> "$(BUILD_LOG)"; cp input input.o; }
	@test ! -e "$(FAIL_BUILD)" || { rm -rf .building; exit 1; }
	@cat input .config > busybox
	@rm -rf .building
distclean:
	@echo clean >> "$(BUILD_LOG)"
	@rm -f .config busybox input.o
defconfig:
	@echo configure >> "$(BUILD_LOG)"
	@printf '# CONFIG_STATIC is not set\nCONFIG_TC=y\nCONFIG_SHA1_HWACCEL=y\n' > .config
oldconfig:
	@echo configure >> "$(BUILD_LOG)"
MAKE
printf 'source v1\n' > "$BUSYBOX_SRC_DIR/input"
printf '*.o\n' > "$BUSYBOX_SRC_DIR/.gitignore"
git -C "$BUSYBOX_SRC_DIR" init -q
git -C "$BUSYBOX_SRC_DIR" add .
git -C "$BUSYBOX_SRC_DIR" -c user.name=test -c user.email=test@example.com commit -qm initial
BUSYBOX_REF=$(git -C "$BUSYBOX_SRC_DIR" rev-parse HEAD)
for compiler in gcc riscv64-linux-gnu-gcc riscv64-linux-gnu-ld riscv64-linux-gnu-as riscv64-linux-gnu-ar riscv64-linux-gnu-strip; do
    printf '#!/bin/sh\necho fixture-compiler-v1\n' > "$work/bin/$compiler"
    chmod +x "$work/bin/$compiler"
done
MKFS_ARCH=x86_64
run_build() (
    composition_dir=$(mktemp -d "$work/composition.XXXXXX")
    mkfs_prepare_busybox_source || exit 1
    mkfs_build_busybox || exit 1
    cp "$BUSYBOX_BUILD_SRC_DIR/busybox" "$composition_dir/result"
    printf '%s\n' "$composition_dir" > "$work/last"
)
count() { grep -c "^$1$" "$BUILD_LOG" || :; }
assert_count() { [[ $(count "$1") == "$2" ]] || { echo "expected $2 $1 calls, got $(count "$1")" >&2; exit 1; }; }
run_build
run_build
assert_count configure 1
assert_count build 2
assert_count compile 1
printf 'ok - repeat uses existing configuration and runs make\n'
printf noise > "$BUSYBOX_SRC_DIR/ignored.o"
printf metadata > "$BUSYBOX_SRC_DIR/.git/unrelated-metadata"
run_build
assert_count configure 1
printf 'ok - ignored objects and git metadata do not invalidate\n'
printf 'source v2\n' > "$BUSYBOX_SRC_DIR/input"
git -C "$BUSYBOX_SRC_DIR" add input
git -C "$BUSYBOX_SRC_DIR" -c user.name=test -c user.email=test@example.com commit -qm change
BUSYBOX_REF=$(git -C "$BUSYBOX_SRC_DIR" rev-parse HEAD)
run_build
assert_count configure 2
printf '#!/bin/sh\necho fixture-compiler-v2\n' > "$work/bin/gcc"
run_build
assert_count configure 3
MKFS_ARCH=riscv64
run_build
assert_count configure 4
MKFS_ARCH=x86_64
printf 'CONFIG_STATIC=y\n# CONFIG_TC is not set\n' > "$work/custom.config"
BUSYBOX_CONFIG="$work/custom.config"
run_build
assert_count configure 5
printf 'CONFIG_EXTRA=y\n' >> "$work/custom.config"
run_build
assert_count configure 6
unset BUSYBOX_CONFIG
cat > "$BUSYBOX_PATCH_DIR/change.patch" <<'PATCH'
diff --git a/input b/input
--- a/input
+++ b/input
@@ -1 +1 @@
-source v2
+patched source
PATCH
run_build
assert_count configure 7
printf 'ok - source, compiler, architecture, configuration, patches invalidate\n'
run_build & first=$!
run_build & second=$!
wait "$first"
wait "$second"
assert_count configure 7
printf 'ok - concurrent same-key builds serialize\n'
last=$(cat "$work/last")
cp "$last/busybox-source/busybox" "$work/previous"
touch "$FAIL_BUILD"
if run_build; then echo 'failed build unexpectedly succeeded' >&2; exit 1; fi
cmp "$work/previous" "$last/busybox-source/busybox"
rm "$FAIL_BUILD"
run_build
assert_count configure 8
printf 'ok - failed build preserves private artifact and recovers cleanly\n'
BUSYBOX_INCREMENTAL=0 run_build
BUSYBOX_INCREMENTAL=0 run_build
assert_count configure 10
printf 'ok - bypass configures afresh\n'
if BUSYBOX_INCREMENTAL=invalid run_build; then
    echo 'invalid incremental mode unexpectedly succeeded' >&2
    exit 1
fi
printf 'ok - invalid incremental mode is rejected\n'
original_script_dir=$BUSYBOX_SCRIPT_DIR
mkdir -p "$work/recipe/rootfs" "$work/recipe/lib"
cp "$BUSYBOX_SCRIPT_DIR/busybox.sh" "$work/recipe/rootfs/"
cp "$BUSYBOX_SCRIPT_DIR/../lib/busybox-source-key.py" "$work/recipe/lib/"
BUSYBOX_SCRIPT_DIR="$work/recipe/rootfs"
run_build
assert_count configure 10
printf '\n# recipe revision\n' >> "$BUSYBOX_SCRIPT_DIR/busybox.sh"
run_build
assert_count configure 11
printf '\n# fingerprint revision\n' >> "$BUSYBOX_SCRIPT_DIR/../lib/busybox-source-key.py"
run_build
assert_count configure 12
BUSYBOX_SCRIPT_DIR=$original_script_dir
printf 'ok - build recipe and fingerprint helper changes invalidate\n'

[[ -z $(find "$work" -type f -name '*.lock' -print -quit) ]] || {
    echo 'FAIL: completed operations leave lock files behind' >&2
    exit 1
}
