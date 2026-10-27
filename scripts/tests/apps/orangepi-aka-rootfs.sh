#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
compiler=${AARCH64_CC:-$(command -v aarch64-linux-gnu-gcc || command -v aarch64-linux-musl-gcc || true)}
command -v "$compiler" >/dev/null || { echo "Need AArch64 cross compiler: $compiler" >&2; exit 1; }
case "$("$compiler" -dumpmachine)" in aarch64*) ;; *) exit 1 ;; esac
tree="$work/tree" package="$work/package"
mkdir -p "$tree/lib/aarch64-linux-gnu" "$tree/usr/lib/aarch64-linux-gnu" "$tree/etc" \
    "$package/bin" "$package/lib" "$package/models" "$package/config"
printf 'void dependency(void) {}\n' >"$work/dependency.c"
"$compiler" -fPIC -shared -nostdlib -Wl,-soname,libdependency.so "$work/dependency.c" \
    -o "$tree/usr/lib/aarch64-linux-gnu/libdependency.so"
printf 'extern void dependency(void); void _start(void) { dependency(); for (;;) {} }\n' >"$work/main.c"
"$compiler" -nostdlib -Wl,-e,_start -Wl,--dynamic-linker=/lib/ld-test-aarch64.so.1 \
    "$work/main.c" -L"$tree/usr/lib/aarch64-linux-gnu" -ldependency -o "$package/bin/tennis-perception"
cp "$tree/usr/lib/aarch64-linux-gnu/libdependency.so" "$tree/lib/aarch64-linux-gnu/ld-test-aarch64.so.1"
ln -s aarch64-linux-gnu/ld-test-aarch64.so.1 "$tree/lib/ld-test-aarch64.so.1"
for name in librknnrt.so libuvc.so.0 libusb-1.0.so.0 libturbojpeg.so.0 libjpeg.so.8 libudev.so.1; do
    cp "$tree/usr/lib/aarch64-linux-gnu/libdependency.so" "$package/lib/$name"
done
printf 'preserve-me\n' >"$tree/etc/rootfs-marker"
printf '{}' >"$package/config/lekiwi_calibration.json"
printf config >"$package/config/lekiwi_pick_config.txt"
printf model >"$package/models/tennis.rknn"
printf '#!/bin/sh\nexit 0\n' >"$package/run_dual_pick_ci_once.sh"
chmod +x "$package/run_dual_pick_ci_once.sh"
truncate -s 64M "$work/base.img"
mke2fs -q -t ext4 -F -d "$tree" "$work/base.img"
before=$(sha256sum "$work/base.img"); before=${before%% *}
compose() {
    ORANGEPI_GUEST_FREE_SIZE=4M bash "$root/scripts/apps/orangepi-aka-rootfs.sh" \
        --base-image "$1" --aka-package "$package" --output "$2"
}
compose "$work/base.img" "$work/good.img" >"$work/good.log" 2>&1 || { cat "$work/good.log"; exit 1; }
[[ $(debugfs -R 'cat /etc/rootfs-marker' "$work/good.img" 2>/dev/null) == preserve-me ]]
grep -q '^AKA_ROOTFS_READY ' "$work/good.log"
cp "$package/bin/tennis-perception" "$work/good-program"
cp /bin/true "$package/bin/tennis-perception"
if compose "$work/base.img" "$work/bad-program.img" >"$work/bad-program.log" 2>&1; then
    echo 'Wrong architecture executable was accepted' >&2; exit 1
fi
[[ ! -e "$work/bad-program.img" && ! -e "$work/bad-program.img.sources.sha256" ]] || {
    echo 'Failed AKA composition published an output image' >&2; exit 1;
}
cp "$work/good-program" "$package/bin/tennis-perception"
cp "$package/lib/librknnrt.so" "$work/good-library"
cp /bin/true "$package/lib/librknnrt.so"
if compose "$work/base.img" "$work/bad-runtime.img" >"$work/bad-runtime.log" 2>&1; then
    echo 'Wrong architecture runtime library was accepted' >&2; exit 1
fi
[[ ! -e "$work/bad-runtime.img" ]]
cp "$work/good-library" "$package/lib/librknnrt.so"
cp "$work/base.img" "$work/no-loader.img"
debugfs -w -R 'rm /lib/aarch64-linux-gnu/ld-test-aarch64.so.1' "$work/no-loader.img" >/dev/null 2>&1
if compose "$work/no-loader.img" "$work/bad-loader.img" >"$work/bad-loader.log" 2>&1; then
    echo 'Missing ELF interpreter was accepted' >&2; exit 1
fi
grep -q 'Missing guest ELF interpreter' "$work/bad-loader.log"
[[ ! -e "$work/bad-loader.img" ]]
after=$(sha256sum "$work/base.img"); after=${after%% *}
[[ $before == "$after" ]]
echo 'AKA guest composition: PASS (content, dependency architecture, interpreter, atomic failure, unchanged base)'
