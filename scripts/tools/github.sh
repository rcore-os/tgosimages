#!/usr/bin/env bash

set -euo pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${TOOLS_DIR}/../.." && pwd -P)
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"
START_DIR="$(pwd -P)"

source "${TOOLS_DIR}/../lib/utils.sh"

GITHUB_TOKEN=""
REPO="rcore-os/tgosimages"
TAG="v0.0.10"
PACK_INPUT_DIR="${ROOT_DIR}/IMAGES"
ASSET_DIR="${ROOT_DIR}/release"
PACK_BEFORE_PUBLISH=0
GENERATE_REGISTRY=0
REGISTRY_DIR="${ROOT_DIR}/registry"

github_usage() {
    printf 'Publish release assets to GitHub Releases\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tools/github.sh [options]\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --token <GITHUB_TOKEN>      GitHub access token (required)\n'
    printf '  --repo <owner/repo>         GitHub repository (required)\n'
    printf '  --tag <tag>                 Release tag (required)\n'
    printf '  --pack [in_dir,out_dir]     Pack in_dir, then publish files from out_dir\n'
    printf '  --registry [dir]            Generate registry/<tag>.toml from local assets\n'
    printf '  help, -h, --help            Display this help information\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * --pack defaults to IMAGES,release when no value is provided.\n'
    printf '  * --pack first runs scripts/tools/pack.sh with <in_dir> and <out_dir>.\n'
    printf '  * After packing, github.sh publishes the files currently present in <out_dir>.\n'
    printf '  * --registry generates a TOML file using the local packed assets without needing GitHub upload.\n'
    printf '  * If the release tag already exists, the existing release is reused.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/github.sh --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
    printf '  scripts/tools/github.sh --pack --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
    printf '  scripts/tools/github.sh --pack IMAGES,release --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
    printf '  scripts/tools/github.sh --pack --registry --repo owner/repo --tag v1.0.0\n'
}

parse_pack_spec() {
    local pack_spec="$1"
    local in_dir=""
    local out_dir=""

    IFS=',' read -r in_dir out_dir <<< "${pack_spec}"

    [[ -n "${in_dir}" ]] && PACK_INPUT_DIR="${in_dir}"
    [[ -n "${out_dir}" ]] && ASSET_DIR="${out_dir}"
}

github_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            --repo)
                REPO="$2"
                shift 2
                ;;
            --tag)
                TAG="$2"
                shift 2
                ;;
            --pack)
                PACK_BEFORE_PUBLISH=1
                if [[ $# -ge 2 && "${2}" != --* ]]; then
                    parse_pack_spec "$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --registry)
                GENERATE_REGISTRY=1
                if [[ $# -ge 2 && "${2}" != --* ]]; then
                    REGISTRY_DIR="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -h|--help|help)
                github_usage
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

github_extract_upload_url() {
    local response_body="$1"
    echo "${response_body}" | grep -oP '"upload_url":\s*"\K[^"{]+'
}

github_get_release_upload_url() {
    local repo="$1"
    local tag="$2"
    local response
    local status_code
    local response_body

    response=$(curl -s -w "%{http_code}" "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json")
    status_code=${response: -3}
    response_body=${response:0:${#response}-3}

    if [[ "${status_code}" -eq 200 ]]; then
        github_extract_upload_url "${response_body}"
        return 0
    fi

    return 1
}

github_create_release() {
    local repo="$1"
    local tag="$2"
    local response
    local status_code
    local response_body

    response=$(curl -s -w "%{http_code}" -X POST "https://api.github.com/repos/${repo}/releases" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"tag_name\": \"${tag}\", \"name\": \"Release ${tag}\", \"body\": \"Auto-generated release\", \"draft\": false, \"prerelease\": false}")
    status_code=${response: -3}
    response_body=${response:0:${#response}-3}

    if [[ "${status_code}" -eq 201 ]]; then
        github_extract_upload_url "${response_body}"
        return 0
    fi

    warn "Failed to create release (HTTP ${status_code})"
    echo "${response_body}" >&2
    return 1
}

github_upload() {
    local base_url="$1"
    local file_path="$2"
    local file_name
    local upload_url
    local response
    local status_code
    local response_body

    file_name=$(basename "${file_path}")
    upload_url="${base_url%%\{*}?name=${file_name}"

    response=$(curl -s -w "%{http_code}" -X POST "${upload_url}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        -H "Accept: application/vnd.github.v3+json" \
        --upload-file "${file_path}")
    status_code=${response: -3}
    response_body=${response:0:${#response}-3}

    if [[ "${status_code}" -eq 201 ]]; then
        success "Upload successful: ${upload_url}"
        return 0
    fi

    warn "Upload failed: ${upload_url} (HTTP ${status_code})"
    echo "${response_body}" >&2
    return 1
}

strip_archive_suffix() {
    local file_name="$1"

    file_name="${file_name%.tar.xz}"
    file_name="${file_name%.txz}"
    file_name="${file_name%.tar.gz}"
    file_name="${file_name%.tgz}"
    printf '%s\n' "${file_name}"
}

registry_version_from_tag() {
    local tag="$1"
    printf '%s\n' "${tag#v}"
}

registry_released_at() {
    local file_path="$1"
    date -u -r "${file_path}" '+%Y-%m-%dT%H:%M:%SZ'
}

registry_sha256() {
    local file_path="$1"
    sha256sum "${file_path}" | awk '{print $1}'
}

registry_os_display_name() {
    local os_name="$1"

    case "${os_name}" in
        arceos) printf 'ArceOS\n' ;;
        starry) printf 'StarryOS\n' ;;
        linux) printf 'Linux\n' ;;
        zephyr) printf 'Zephyr\n' ;;
        freertos) printf 'FreeRTOS\n' ;;
        rtthread) printf 'RT-Thread\n' ;;
        alpine) printf 'Alpine\n' ;;
        busybox) printf 'BusyBox\n' ;;
        debian) printf 'Debian\n' ;;
        bundle) printf 'Guest bundle\n' ;;
        *) printf '%s\n' "${os_name}" ;;
    esac
}

registry_target_display_name() {
    local target="$1"

    case "${target}" in
        evm3588) printf 'EVM3588 development board\n' ;;
        orangepi|orangepi-5-plus) printf 'Orange Pi development board\n' ;;
        phytiumpi) printf 'Phytium Pi development board\n' ;;
        roc-rk3568-pc) printf 'ROC-RK3568-PC development board\n' ;;
        tac-e400-plc) printf 'TAC-E400-PLC industrial control board\n' ;;
        rdk-s100p) printf 'RDK-S100P development board\n' ;;
        bst-a1000) printf 'BST-A1000 development board\n' ;;
        qemu-aarch64) printf 'QEMU aarch64 virtualization\n' ;;
        qemu-riscv64) printf 'QEMU riscv64 virtualization\n' ;;
        qemu-x86_64) printf 'QEMU x86_64 virtualization\n' ;;
        qemu-loongarch64) printf 'QEMU LoongArch64 virtualization\n' ;;
        *) return 1 ;;
    esac
}

registry_emit_entry() {
    local output_file="$1"
    local name="$2"
    local version="$3"
    local description="$4"
    local sha256="$5"
    local arch="$6"
    local url="$7"
    local released_at="$8"

    cat >> "${output_file}" <<EOF
[[images]]
name = "${name}"
version = "${version}"
description = "${description}"
sha256 = "${sha256}"
arch = "${arch}"
url = "${url}"
released_at = "${released_at}"

EOF
}

registry_add_rootfs_entry() {
    local output_file="$1"
    local asset_file="$2"
    local asset_name="$3"
    local stem="$4"
    local version="$5"
    local url="$6"
    local released_at="$7"
    local kind="$8"
    local arch="$9"
    local builder="${10}"
    local builder_display
    local description

    builder_display="$(registry_os_display_name "${builder}")"
    if [[ "${kind}" == "rootfs" ]]; then
        description="${builder_display} rootfs image for ${arch}"
    else
        description="${builder_display} initramfs for ${arch}"
    fi

    registry_emit_entry \
        "${output_file}" \
        "${stem}" \
        "${version}" \
        "${description}" \
        "$(registry_sha256 "${asset_file}")" \
        "${arch}" \
        "${url}" \
        "${released_at}"
}

registry_add_os_entry() {
    local output_file="$1"
    local asset_file="$2"
    local asset_name="$3"
    local stem="$4"
    local version="$5"
    local url="$6"
    local released_at="$7"
    local target="$8"
    local arch="$9"
    local os_name="${10}"
    local os_display
    local target_display

    os_display="$(registry_os_display_name "${os_name}")"
    target_display="$(registry_target_display_name "${target}")" || {
        warn "Skipping unsupported registry target for asset: ${asset_name}"
        return 1
    }

    registry_emit_entry \
        "${output_file}" \
        "${stem}" \
        "${version}" \
        "${os_display} for ${target_display}" \
        "$(registry_sha256 "${asset_file}")" \
        "${arch}" \
        "${url}" \
        "${released_at}"
}

registry_add_platform_bundle_entry() {
    local output_file="$1"
    local asset_file="$2"
    local asset_name="$3"
    local stem="$4"
    local version="$5"
    local url="$6"
    local released_at="$7"
    local target="$8"
    local arch="$9"
    local target_display

    target_display="$(registry_target_display_name "${target}")" || {
        warn "Skipping unsupported registry target for asset: ${asset_name}"
        return 1
    }

    registry_emit_entry \
        "${output_file}" \
        "${stem}" \
        "${version}" \
        "Guest image bundle for ${target_display}" \
        "$(registry_sha256 "${asset_file}")" \
        "${arch}" \
        "${url}" \
        "${released_at}"
}

registry_process_asset() {
    local output_file="$1"
    local asset_file="$2"
    local version="$3"
    local released_at="$4"
    local asset_name
    local stem
    local url
    local target
    local arch
    local os_name

    asset_name="$(basename "${asset_file}")"
    stem="$(strip_archive_suffix "${asset_name}")"
    url="https://github.com/${REPO}/releases/download/${TAG}/${asset_name}"

    if [[ "${stem}" =~ ^rootfs-([A-Za-z0-9_]+)-([A-Za-z0-9_-]+)\.img$ ]]; then
        registry_add_rootfs_entry "${output_file}" "${asset_file}" "${asset_name}" "${stem}" "${version}" "${url}" "${released_at}" "rootfs" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    if [[ "${stem}" =~ ^initramfs-([A-Za-z0-9_]+)-([A-Za-z0-9_-]+)\.cpio\.gz$ ]]; then
        registry_add_rootfs_entry "${output_file}" "${asset_file}" "${asset_name}" "${stem}" "${version}" "${url}" "${released_at}" "initramfs" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    if [[ "${stem}" == "orangepi-5-plus.img" ]]; then
        registry_emit_entry "${output_file}" "${stem}" "${version}" \
            "Bootable disk image for Orange Pi development board" \
            "$(registry_sha256 "${asset_file}")" "aarch64" "${url}" "${released_at}"
        return 0
    fi

    # qemu-<arch>-<os>: separator must be '-' (not '_'), otherwise arches like
    # "x86_64" would be split incorrectly. Fall through on failure so the
    # qemu-<arch> bundle branch below can handle bare arches.
    if [[ "${stem}" =~ ^qemu[-_]([A-Za-z0-9_]+)-([A-Za-z0-9-]+)$ ]]; then
        arch="${BASH_REMATCH[1]}"
        os_name="${BASH_REMATCH[2]}"
        if registry_add_os_entry "${output_file}" "${asset_file}" "${asset_name}" "${stem}" "${version}" "${url}" "${released_at}" "qemu-${arch}" "${arch}" "${os_name}"; then
            return 0
        fi
    fi

    if [[ "${stem}" =~ ^qemu[-_]([A-Za-z0-9_]+)$ ]]; then
        arch="${BASH_REMATCH[1]}"
        registry_add_platform_bundle_entry "${output_file}" "${asset_file}" "${asset_name}" "${stem}" "${version}" "${url}" "${released_at}" "qemu-${arch}" "${arch}"
        return 0
    fi

    # Board guest bundles containing multiple OSes.
    case "${stem}" in
        phytiumpi|orangepi)
            registry_add_platform_bundle_entry "${output_file}" "${asset_file}" "${asset_name}" "${stem}" "${version}" "${url}" "${released_at}" "${stem}" "aarch64"
            return 0
            ;;
    esac

    if [[ "${stem}" =~ ^(.+)[-_](arceos|linux|zephyr|freertos|rtthread|starry)$ ]]; then
        target="${BASH_REMATCH[1]}"
        os_name="${BASH_REMATCH[2]}"
        case "${target}" in
            evm3588|orangepi|orangepi-5-plus|phytiumpi|roc-rk3568-pc|tac-e400-plc|rdk-s100p|bst-a1000)
                registry_add_os_entry "${output_file}" "${asset_file}" "${asset_name}" "${stem}" "${version}" "${url}" "${released_at}" "${target}" "aarch64" "${os_name}"
                return 0
                ;;
        esac
    fi

    warn "Skipping unsupported registry asset: ${asset_name}"
    return 1
}

github_generate_registry() {
    local output_dir="$1"
    local version
    local output_file
    local asset_file
    local processed_count=0
    local skipped_count=0

    mkdir -p "${output_dir}"
    version="$(registry_version_from_tag "${TAG}")"
    output_file="${output_dir}/${TAG}.toml"

    cat > "${output_file}" <<EOF
# Guest image list for TGOS images (${TAG})

EOF

    shopt -s nullglob dotglob
    files=("${ASSET_DIR}"/*)
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Asset directory is empty, generated registry will contain no images."
    else
        IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort))
        for asset_file in "${files[@]}"; do
            if [[ ! -f "${asset_file}" ]]; then
                continue
            fi
            if registry_process_asset "${output_file}" "${asset_file}" "${version}" "$(registry_released_at "${asset_file}")"; then
                processed_count=$((processed_count + 1))
            else
                skipped_count=$((skipped_count + 1))
            fi
        done
    fi
    shopt -u nullglob dotglob

    success "Registry TOML generated: ${output_file} (${processed_count} images)"
    if [[ "${skipped_count}" -gt 0 ]]; then
        warn "Registry skipped ${skipped_count} unsupported assets"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        github_usage
        exit 0
    fi

    github_parse_args "$@"
    PACK_INPUT_DIR="$(normalize_dir_path "${PACK_INPUT_DIR}")"
    ASSET_DIR="$(normalize_dir_path "${ASSET_DIR}")"
    REGISTRY_DIR="$(normalize_dir_path "${REGISTRY_DIR}")"

    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 && ! -d "${PACK_INPUT_DIR}" ]]; then
        die "Input directory does not exist: ${PACK_INPUT_DIR}"
    fi

    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 ]]; then
        local_pack_args=(--in_dir "${PACK_INPUT_DIR}" --out_dir "${ASSET_DIR}")
        info "Packing release assets before publishing..."
        bash "${TOOLS_DIR}/pack.sh" "${local_pack_args[@]}"
    fi

    if [[ -z "${REPO}" ]]; then
        die "REPO must be set via --repo"
    fi
    if [[ -z "${TAG}" ]]; then
        die "TAG must be set via --tag"
    fi
    if [[ ! -d "${ASSET_DIR}" ]]; then
        die "Asset directory does not exist: ${ASSET_DIR}"
    fi

    if [[ "${GENERATE_REGISTRY}" -eq 1 ]]; then
        info "Generating registry TOML..."
        github_generate_registry "${REGISTRY_DIR}"
    fi

    if [[ -z "${GITHUB_TOKEN}" ]]; then
        if [[ "${GENERATE_REGISTRY}" -eq 1 ]]; then
            exit 0
        fi
        die "GITHUB_TOKEN must be set via --token"
    fi

    info "GitHub repository: ${REPO}"
    info "Release tag: ${TAG}"
    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 ]]; then
        info "Pack input directory: ${PACK_INPUT_DIR}"
    fi
    info "Asset directory: ${ASSET_DIR}"
    info "Number of asset files: $(find "${ASSET_DIR}" -maxdepth 1 -type f | wc -l)"
    info "Resolving release..."

    upload_url="$(github_get_release_upload_url "${REPO}" "${TAG}" || true)"
    if [[ -n "${upload_url}" ]]; then
        success "Using existing release for tag ${TAG}"
    else
        info "Creating release..."
        upload_url=$(github_create_release "${REPO}" "${TAG}") || exit 1
        success "Release created successfully"
    fi
    [[ -n "${upload_url}" ]] || die "Failed to create release"
    info "Starting to upload asset files..."

    uploaded_count=0
    skipped_count=0
    shopt -s nullglob dotglob
    files=("${ASSET_DIR}"/*)
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Asset directory is empty, no files to upload."
    else
        IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort))
        for file in "${files[@]}"; do
            if [[ -f "${file}" ]]; then
                if github_upload "${upload_url}" "${file}"; then
                    ((uploaded_count+=1))
                fi
            else
                warn "Skipping non-file asset: ${file}"
                ((skipped_count+=1))
            fi
        done
    fi
    shopt -u nullglob dotglob

    success "Number of files uploaded: ${uploaded_count}"
    if [[ "${skipped_count}" -gt 0 ]]; then
        warn "Number of skipped non-file assets: ${skipped_count}"
    fi
    info "Release URL: https://github.com/${REPO}/releases/tag/${TAG}"
fi
