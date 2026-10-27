#!/usr/bin/env bash

# Build into a caller-owned private package stage. Its parent publishes only
# after the host, every guest input, and the complete configuration set succeed.
axvisor_payload_kernel() (
    local kind=$1 config=$2 package=$3 output=$4
    local target="$BUILD_DIR/objects/axvisor-guests/$kind" log="$output.log" elf status=0
    local -a args=(xtask "$kind" build --target aarch64-unknown-none-softfloat --config "$config")
    [[ -z $package ]] || args+=(-p "$package")
    [[ $kind != starry ]] || args+=(--smp 1)
    mkdir -p -- "$(dirname -- "$output")" "$target" || return 1
    (
        cd -- "$AXVISOR_SRC_DIR" || exit 1
        export AXBUILD_NO_SNAPSHOT=1 CARGO_TARGET_DIR="$target"
        build_cargo "${args[@]}"
    ) 2>&1 | tee "$log" || status=$?
    ((status == 0)) || return "$status"
    elf=$(sed -n 's/^\[axbuild\] cargo build elf=//p' "$log" | tail -1)
    [[ -n $elf ]] || { error "$kind did not report its ELF artifact"; return 1; }
    elf=$(realpath -e -- "$elf") || return 1
    [[ $elf == "$(realpath -e -- "$target")/"* && -s $elf ]] || return 1
    (cd -- "$AXVISOR_SRC_DIR" && axvisor_objcopy "$elf" "$output") || return 1
    [[ -s $output ]] || return 1
    rm -- "$log"
)

axvisor_payload_yolo() (
    local stage=$1 project="$AXVISOR_SRC_DIR/apps/axvisor/normal/board-ballpick-robot/linux-guest-checks/rknn-yolov8-image"
    local object="$BUILD_DIR/objects/axvisor-yolov8" cc=${ORANGEPI_YOLO_CC:-} cxx=${ORANGEPI_YOLO_CXX:-}
    local sysroot=${ORANGEPI_YOLO_SYSROOT:-$BUILD_DIR/yolo-sysroot}
    local sdk_flags
    local -a extra=() candidates=()
    [[ -f $project/CMakeLists.txt ]] || { error "YOLOv8 source missing: $project"; return 1; }
    if [[ -z $cc ]]; then
        shopt -s nullglob
        candidates=("$BUILD_DIR"/orangepi/toolchains/*/bin/aarch64*-gcc)
        for cc in "${candidates[@]}"; do [[ -x $cc ]] && break; done
        [[ -n $cc ]] || cc=$(command -v aarch64-linux-gnu-gcc-9 || command -v aarch64-linux-gnu-gcc || true)
    fi
    cxx=${cxx:-${cc%gcc}g++}
    # Version-suffixed system compilers need the same C++ version.
    if [[ $cc == *-gcc-[0-9]* && -z ${ORANGEPI_YOLO_CXX:-} ]]; then cxx=${cc/-gcc-/-g++-}; fi
    [[ -x $cc && -x $cxx ]] || { error 'Set ORANGEPI_YOLO_CC/CXX to AArch64 GNU/Linux compilers'; return 1; }
    [[ $("$cc" -dumpmachine) == aarch64*linux-gnu* ]] || { error 'YOLOv8 requires an AArch64 glibc toolchain'; return 1; }
    if [[ -z ${ORANGEPI_YOLO_SYSROOT:-} ]]; then
        python3 "$ROOT_DIR/scripts/lib/python/aka-package.py" runtime \
            --lock "${ORANGEPI_AKA_DEPENDENCY_LOCK:-$ROOT_DIR/scripts/apps/aka-runtime.lock.json}" \
            --cache "${BUILD_CACHE_DIR:-$ROOT_DIR/build/.cache}/aka-debs" --sysroot "$sysroot" || return 1
    fi
    # Retain C++ wrappers, then search only the selected target C headers.
    sdk_flags=$(python3 "$ROOT_DIR/scripts/lib/python/aka-package.py" header-flags \
        --cc "$cc" --cxx "$cxx" --sysroot "$sysroot") || return 1
    mapfile -t sdk_flags <<< "$sdk_flags"
    extra+=("-DCMAKE_SYSROOT=$sysroot"
        "-DCMAKE_C_FLAGS=${sdk_flags[0]}"
        "-DCMAKE_CXX_FLAGS=${sdk_flags[1]}")
    # Link against the selected SDK's C++ libraries even when it only ships
    # SONAME files. The private linker aliases never modify the target SDK.
    python3 "$ROOT_DIR/scripts/lib/python/linux-runtime.py" --sysroot "$sysroot" \
        --copy-libraries "$stage/npu/rknn-yolov8-image/lib" libstdc++.so.6 libgcc_s.so.1 || return 1
    cmake -S "$project" -B "$object" -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
        "-DCMAKE_EXE_LINKER_FLAGS=-L$stage/npu/rknn-yolov8-image/lib -B$sysroot/usr/lib/aarch64-linux-gnu -L$sysroot/usr/lib/aarch64-linux-gnu -L$sysroot/lib/aarch64-linux-gnu -Wl,-rpath-link,$stage/npu/rknn-yolov8-image/lib -Wl,-rpath-link,$sysroot/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,$sysroot/lib/aarch64-linux-gnu" \
        -DCMAKE_INSTALL_PREFIX="$stage/npu/rknn-yolov8-image" "${extra[@]}" || return 1
    cmake --build "$object" --parallel "$(build_jobs)" || return 1
    cmake --install "$object" || return 1
    if [[ -d $sysroot/runtime/licenses ]]; then
        cp -a -- "$sysroot/runtime/licenses/." "$stage/npu/rknn-yolov8-image/licenses/" || return 1
    fi
    python3 "$ROOT_DIR/scripts/lib/python/linux-runtime.py" \
        --sysroot "$sysroot" \
        "$stage/npu/rknn-yolov8-image/rknn_yolov8_images" \
        "$stage/npu/rknn-yolov8-image/lib/librknnrt.so" \
        "$stage/npu/rknn-yolov8-image/lib/librga.so" \
        "$stage/npu/rknn-yolov8-image/lib/libstdc++.so.6" \
        "$stage/npu/rknn-yolov8-image/lib/libgcc_s.so.1"
)

axvisor_stage_payloads() (
    local stage=$1 board=apps/axvisor/normal/board-ballpick-robot
    local generated= generator
    mkdir -p "$BUILD_DIR/objects" || return 1
    generated=$(mktemp -d "$BUILD_DIR/objects/.axvisor-network.XXXXXX") || return 1
    trap 'rm -rf -- "$generated"' EXIT
    axvisor_payload_kernel arceos "$board/kernel-types/arceos/configs/guest-build.toml" \
        arceos-vm-shell "$stage/guests/arceos-vm-shell.bin" || return $?
    axvisor_payload_kernel starry \
        test-suit/starryos/board-orangepi-5-plus/robot-flow/build-aarch64-unknown-none-softfloat.toml \
        '' "$stage/guests/starry-robot-single.bin" || return $?
    axvisor_payload_yolo "$stage" || return $?
    # The upstream generator derives its output from its own script location.
    # Run an unchanged copy in a private skeleton, never in a supplied checkout.
    generator="$generated/$board/virtio-net-peer/vcpus/orangepi-arceos-virtio-net-test.sh"
    mkdir -p "$(dirname -- "$generator")" || return 1
    cp -- "$AXVISOR_SRC_DIR/$board/virtio-net-peer/vcpus/orangepi-arceos-virtio-net-test.sh" "$generator" || return 1
    bash "$generator" gen || return $?
    python3 "$ROOT_DIR/scripts/lib/python/axvisor-payloads.py" "$AXVISOR_SRC_DIR" "$stage" \
        --network-configs "$generated/target/axvisor-arceos-net-scale"
)
