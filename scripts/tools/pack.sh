#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"
START_DIR="$(pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

IMAGES_DIR="${ROOT_DIR}/IMAGES"
RELEASE_DIR="${ROOT_DIR}/release"
PACK_PER_FILE=0

pack_usage() {
    printf 'Package image artifacts into release archives\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tools/pack.sh [options]\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --in_dir, --input_dir, -i <dir>   Directory containing images (default: IMAGES)\n'
    printf '  --out_dir, --output_dir, -o <dir> Output directory for packaged archives (default: release)\n'
    printf '  --per-file                        Package each direct child of <dir> into its own archive\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * Default mode is release-oriented:\n'
    printf '      - each file under <dir>/rootfs becomes its own .tar.xz archive\n'
    printf '      - each non-rootfs direct child of <dir> becomes its own .tar.xz archive\n'
    printf '  * With --per-file, each direct child of <dir> is packaged into an individual .tar.xz archive.\n'
    printf '  * Direct children can be either files or directories.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/pack.sh\n'
    printf '  scripts/tools/pack.sh --in_dir IMAGES --out_dir release\n'
    printf '  scripts/tools/pack.sh --per-file --in_dir IMAGES --out_dir release\n'
}

pack_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --in_dir|--input_dir|-i)
                IMAGES_DIR="$2"
                shift 2
                ;;
            --out_dir|--output_dir|-o)
                RELEASE_DIR="$2"
                shift 2
                ;;
            --per-file)
                PACK_PER_FILE=1
                shift
                ;;
            -h|--help|help)
                pack_usage
                exit 0
                ;;
            *)
                die "Unknown option: $1" 2
                ;;
        esac
    done
}

normalize_dir_path() {
    local dir_path="$1"

    if [[ "${dir_path}" = /* ]]; then
        printf '%s\n' "${dir_path}"
    else
        printf '%s\n' "${START_DIR}/${dir_path}"
    fi
}

pack_tar_with_xz() {
    local out_path="$1"
    shift

    # Use strong xz compression to improve the ratio for single large image files.
    tar -I 'xz -T0 -9e' -cf "${out_path}" "$@"
}

pack_path() {
    local source_path="$1"
    local package_stem="$2"
    local out_path="${RELEASE_DIR}/${package_stem}.tar.xz"

    info "Packing ${source_path} -> ${out_path}"

    if [[ -d "${source_path}" ]]; then
        pack_tar_with_xz "${out_path}" -C "${source_path}" .
    else
        pack_tar_with_xz "${out_path}" -C "$(dirname "${source_path}")" "$(basename "${source_path}")"
    fi
}

pack_release_layout() {
    local source_dir="$1"
    local count_packed=0
    local count_skipped=0
    local child_path
    local rootfs_path="${source_dir}/rootfs"
    local package_stem

    mkdir -p "${RELEASE_DIR}"

    if [[ -d "${rootfs_path}" ]]; then
        while IFS= read -r child_path; do
            [[ -n "${child_path}" ]] || continue
            if [[ "$(basename "${child_path}")" == *.tmp.* ]]; then
                continue
            fi
            if [[ -f "${child_path}" ]]; then
                package_stem="$(basename "${child_path}")"
                pack_path "${child_path}" "${package_stem}"
                count_packed=$((count_packed + 1))
            elif [[ -d "${child_path}" ]]; then
                package_stem="rootfs_$(basename "${child_path}")"
                pack_path "${child_path}" "${package_stem}"
                count_packed=$((count_packed + 1))
            fi
        done < <(pack_child_paths "${rootfs_path}")
    fi

    while IFS= read -r child_path; do
        [[ -n "${child_path}" ]] || continue
        if [[ "${child_path}" == "${rootfs_path}" ]]; then
            continue
        fi
        if [[ "$(basename "${child_path}")" == *.tmp.* ]]; then
            continue
        fi
        package_stem="$(basename "${child_path}")"
        pack_path "${child_path}" "${package_stem}"
        count_packed=$((count_packed + 1))
    done < <(pack_child_paths "${source_dir}")

    if [[ ${count_packed} -eq 0 ]]; then
        warn "Skipping empty directory ${source_dir}"
        count_skipped=$((count_skipped + 1))
    fi

    success "Packaging completed: ${count_packed} archives created, skipped ${count_skipped} empty directories"
}

pack_child_paths() {
    local source_dir="$1"
    local child_path

    shopt -s nullglob dotglob
    for child_path in "${source_dir}"/*; do
        [[ -e "${child_path}" ]] || continue
        printf '%s\n' "${child_path}"
    done
    shopt -u nullglob dotglob
}

pack_images() {
    local count_packed=0
    local count_skipped=0
    local child_path
    local package_stem
    local child_count=0

    mkdir -p "${RELEASE_DIR}"

    if [[ ${PACK_PER_FILE} -eq 0 ]]; then
        pack_release_layout "${IMAGES_DIR}"
        return 0
    fi

    while IFS= read -r child_path; do
        [[ -n "${child_path}" ]] || continue
        if [[ "$(basename "${child_path}")" == *.tmp.* ]]; then
            continue
        fi
        child_count=$((child_count + 1))
        package_stem="$(basename "${child_path}")"
        pack_path "${child_path}" "${package_stem}"
        count_packed=$((count_packed + 1))
    done < <(pack_child_paths "${IMAGES_DIR}")

    if [[ ${child_count} -eq 0 ]]; then
        warn "Skipping empty directory ${IMAGES_DIR}"
        count_skipped=$((count_skipped + 1))
    fi

    success "Packaging completed: ${count_packed} archives created, skipped ${count_skipped} empty directories"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    pack_parse_args "$@"

    IMAGES_DIR="$(normalize_dir_path "${IMAGES_DIR}")"
    RELEASE_DIR="$(normalize_dir_path "${RELEASE_DIR}")"

    if [[ ! -d "${IMAGES_DIR}" ]]; then
        die "Input directory does not exist: ${IMAGES_DIR}"
    fi

    if [[ ${PACK_PER_FILE} -eq 1 ]]; then
        info "Starting to package system images under ${IMAGES_DIR} with per-file archives ..."
    else
        info "Starting to package system images under ${IMAGES_DIR} with release-layout archives ..."
    fi
    pack_images

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'RELEASE_DIR=%s\n' "${RELEASE_DIR}" >> "${GITHUB_OUTPUT}"
    fi
fi
