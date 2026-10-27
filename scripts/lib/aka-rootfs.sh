#!/usr/bin/env bash

# Validate ELF dependencies inside the guest; never resolve links on the host.
aka_validate_guest_image() (
    set -euo pipefail
    local image=$1 stage guest resolved elf dynamic headers interpreter needed found dir name
    local lib_dir
    lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    source "$lib_dir/rootfs-disk.sh"
    stage=$(mktemp -d "$(dirname -- "$image")/.aka-deps.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    local -a queue=(/opt/aka/bin/tennis-perception)
    if rootfs_ext4_resolve_file "$image" /opt/aka/bin/tennis >/dev/null 2>&1; then
        queue+=(/opt/aka/bin/tennis)
    fi
    # These libraries can be selected dynamically, so DT_NEEDED alone is not
    # enough to prove the complete AKA runtime has the correct architecture.
    for name in librknnrt.so libuvc.so.0 libusb-1.0.so.0 libturbojpeg.so.0 libjpeg.so.8 libudev.so.1; do
        queue+=("/opt/aka/lib/$name")
    done
    declare -A checked=()
    local -a binaries=()
    while ((${#queue[@]})); do
        guest=${queue[0]}; queue=("${queue[@]:1}")
        resolved=$(rootfs_ext4_resolve_file "$image" "$guest") || {
            printf 'Missing guest ELF file: %s\n' "$guest" >&2; exit 1;
        }
        [[ -z ${checked[$resolved]+x} ]] || continue
        checked[$resolved]=1
        elf="$stage$resolved"
        mkdir -p -- "$(dirname -- "$elf")"
        _rootfs_run_tool 0 debugfs -R "dump $(_rootfs_debugfs_quote "$resolved") $(_rootfs_debugfs_quote "$elf")" "$image" >/dev/null
        [[ -s $elf ]] || { printf 'Cannot extract guest ELF: %s\n' "$guest" >&2; exit 1; }
        binaries+=("$elf")
        readelf -h "$elf" | awk '/Machine:/ { if ($2 == "AArch64") found=1 } END { exit !found }' || {
            printf 'Expected AArch64 ELF: %s\n' "$guest" >&2; exit 1;
        }
        headers=$(readelf -lW "$elf")
        interpreter=$(sed -n 's/.*Requesting program interpreter: \([^]]*\)\].*/\1/p' <<<"$headers")
        if [[ -n $interpreter ]]; then
            [[ $interpreter == /* ]] && rootfs_ext4_resolve_file "$image" "$interpreter" >/dev/null || {
                printf 'Missing guest ELF interpreter: %s (from %s)\n' "$interpreter" "$guest" >&2; exit 1;
            }
            queue+=("$interpreter")
        fi
        dynamic=$(readelf -d "$elf")
        while IFS= read -r needed; do
            [[ -n $needed ]] || continue
            found=""
            if [[ $needed == /* ]]; then
                found=$(rootfs_ext4_resolve_file "$image" "$needed" 2>/dev/null) || found=""
            else
                [[ $needed != */* ]] || { printf 'Unsupported relative ELF dependency: %s\n' "$needed" >&2; exit 1; }
                for dir in /opt/aka/lib /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu /lib /usr/lib; do
                    if found=$(rootfs_ext4_resolve_file "$image" "$dir/$needed" 2>/dev/null); then break; fi
                    found=""
                done
            fi
            [[ -n $found ]] || { printf 'Missing transitive dependency: %s (from %s)\n' "$needed" "$guest" >&2; exit 1; }
            queue+=("$found")
        done < <(sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' <<<"$dynamic")
    done
    python3 "$lib_dir/python/linux-runtime.py" --sysroot "$stage" \
        --library-dir /opt/aka/lib "${binaries[@]}"
    echo AKA_GUEST_DEPENDENCIES_READY
)
