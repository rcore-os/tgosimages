#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
usage() {
    echo "Usage: orangepi-aka-perception.sh --aka-dir DIR --ivc-sdk-dir DIR --runtime-dir DIR --include-dir DIR --cc PATH --cxx PATH --build-dir DIR --output-dir DIR [--config-dir DIR]"
    echo "Cross-build with real target libraries; never use the AKA unresolved-symbol stubs."
}
aka=""; sdk=""; runtime=""; includes=""; cc=""; cxx=""; build=""; output=""; config=""
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 || "$1" == --help || "$1" == -h ]] || { usage >&2; exit 2; }
    case "$1" in
        --aka-dir) aka=$2 ;;
        --ivc-sdk-dir) sdk=$2 ;;
        --runtime-dir) runtime=$2 ;;
        --include-dir) includes=$2 ;;
        --cc) cc=$2 ;;
        --cxx) cxx=$2 ;;
        --build-dir) build=$2 ;;
        --output-dir) output=$2 ;;
        --config-dir) config=$2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift 2
done
[[ -d "$aka" && -d "$sdk" && -d "$runtime" && -d "$includes" && -x "$cc" && -x "$cxx" && -n "$build" && -n "$output" ]] || { usage >&2; exit 2; }
aka=$(realpath "$aka"); sdk=$(realpath "$sdk"); runtime=$(realpath "$runtime"); includes=$(realpath "$includes")
config="${config:-$aka/config}"
[[ -f $config/lekiwi_calibration.json && -f $config/lekiwi_pick_config.txt ]] || { echo "Missing AKA calibration/config input: $config" >&2; exit 2; }
config=$(realpath "$config")
mkdir -p "$build/pkgconfig" "$(dirname -- "$output")"
stage=$(mktemp -d "$(dirname -- "$output")/.aka-package.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
build=$(realpath "$build"); output=$(realpath -m "$output")
for input in "$aka" "$sdk" "$runtime" "$includes" "$config" "$build" "$ROOT_DIR"; do
    case "$input/" in "$output/"*) echo "Package output would replace an input tree: $output" >&2; exit 2 ;; esac
done
case "$("$cc" -dumpmachine)" in aarch64*) ;; *) echo "AKA requires an AArch64 target compiler" >&2; exit 2 ;; esac
# The upstream real-library branch adds a host /usr/include fallback. Remove
# only that fallback; all target headers come from the selected include tree.
cat > "$build/target-compiler-launcher.py" <<'LAUNCHER'
#!/usr/bin/env python3
import os
import sys
args = [arg for arg in sys.argv[1:] if arg != "-I/usr/include"]
os.execv(args[0], args)
LAUNCHER
chmod +x "$build/target-compiler-launcher.py"
for lib in libuvc.so.0 libusb-1.0.so.0 libturbojpeg.so.0 libjpeg.so.8 libudev.so.1; do
    [[ -f "$runtime/$lib" ]] || { echo "Missing target library: $lib" >&2; exit 2; }
done
for spec in 'libuvc libuvc.so.0' 'libusb-1.0 libusb-1.0.so.0' 'libturbojpeg libturbojpeg.so.0'; do
    read -r name soname <<< "$spec"
    cat > "$build/pkgconfig/$name.pc" <<EOF
prefix=$runtime
Name: $name
Description: Real target runtime for AKA cross build
Version: 1.0
Libs: -L$runtime -l:$soname
Cflags: -I$includes -I$includes/libusb-1.0 -I$aka/3rd/jpeg_turbo/include
EOF
done
# NATIVE_BUILD selects the real-library CMake branch; compilers still target AArch64.
export PKG_CONFIG_LIBDIR="$build/pkgconfig"
export PKG_CONFIG_PATH=""
cmake -S "$aka" -B "$build" -DNATIVE_BUILD=ON -DBUILD_TESTING=OFF -DDISABLE_RGA=ON -DCMAKE_BUILD_TYPE=Release \
    -DIVC_SDK_DIR="$sdk" -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
    -DCMAKE_C_COMPILER_LAUNCHER="$build/target-compiler-launcher.py" \
    -DCMAKE_CXX_COMPILER_LAUNCHER="$build/target-compiler-launcher.py" \
    -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
    -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,--gc-sections -Wl,-rpath-link,$runtime"
cmake --build "$build" --target tennis-perception -j"${JOBS:-4}"
# The broken stub build encoded calls to address zero instead of a dynamic UVC symbol.
readelf --dyn-syms --wide "$build/tennis-perception" | awk '
    $4 == "FUNC" && $7 == "UND" && $8 ~ /^uvc_init(@.*)?$/ { found=1 }
    END { exit !found }
' || { echo "uvc_init must bind to the real dynamic library" >&2; exit 1; }
cmake --install "$build" --component dual-runtime --prefix "$stage"
for lib in libuvc.so.0 libusb-1.0.so.0 libturbojpeg.so.0 libjpeg.so.8 libudev.so.1; do
    cp -L -- "$runtime/$lib" "$stage/lib/$lib"
done
cp -- "$config/lekiwi_calibration.json" "$config/lekiwi_pick_config.txt" "$stage/config/"
if [[ -d $runtime/licenses ]]; then cp -a -- "$runtime/licenses" "$stage/"; fi
python3 "$ROOT_DIR/scripts/lib/python/aka-package.py" manifest \
    --package "$stage" --aka "$aka" --sdk "$sdk" --compiler "$cc" --runtime "$runtime" --config "$config"
[[ ! -L $output ]] || { echo "Package output cannot be a symlink: $output" >&2; exit 2; }
if [[ -e $output ]]; then
    [[ -d $output && $output != / && $output != "$aka" && $output != "$sdk" && $output != "$runtime" && $output != "$build" ]] || exit 2
    rm -rf -- "$output"
fi
mv -- "$stage" "$output"
echo "AKA_PERCEPTION_READY package=$output"
