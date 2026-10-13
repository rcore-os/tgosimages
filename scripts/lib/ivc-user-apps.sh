#!/usr/bin/env bash

# Build the runtime-selectable IVC peer for both Linux and StarryOS.
# The caller provides an already-built SDK static library and musl toolchain.
build_ivc_roundtrip() {
    local images_root=$1 sdk_dir=$2 object_dir=$3
    [[ -s "${object_dir}/libaxivc.a" ]] || die "Missing SDK library: ${object_dir}/libaxivc.a"
    mkdir -p "${object_dir}/examples"
    "${CROSS:-aarch64-linux-musl-}gcc" -std=c11 -O2 -Wall -Wextra -Werror \
        -static -no-pie -I"${sdk_dir}/include" \
        "${images_root}/apps/ivc/ivc-roundtrip.c" "${object_dir}/libaxivc.a" \
        -o "${object_dir}/examples/ivc-roundtrip"
}

# Populate a guest overlay from the platform's shared IVC userspace payload.
stage_ivc_user_apps() {
    local payload=$1 overlay=$2 program
    for program in ivc-demo ivc-starry-bench ivc-roundtrip; do
        [[ -s "$payload/usr/bin/$program" ]] || {
            printf 'Missing IVC guest program: %s/usr/bin/%s\n' "$payload" "$program" >&2
            return 1
        }
    done
    mkdir -p "$overlay/usr/bin" || return 1
    for program in ivc-demo ivc-starry-bench ivc-roundtrip; do
        cp -a -- "$payload/usr/bin/$program" "$overlay/usr/bin/$program" || return 1
        chmod 0755 "$overlay/usr/bin/$program" || return 1
    done
}
