#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../../.." && pwd -P)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

LOG_CREATE_DEFAULT_FILE=0 bash -c '
    source "$1/scripts/os/starry.sh"
    [[ $STARRY_REF == 3531e72e734ada002ee20520f7467e58e5ea69e9 ]]
    starry_parse_args --ref custom-ref
    [[ $STARRY_REF == custom-ref ]]
' _ "$ROOT_DIR"

mkdir -p "${TMP_DIR}/IMAGES/orangepi-5-plus-starry"
printf 'test-starry-image\n' > "${TMP_DIR}/IMAGES/orangepi-5-plus-starry/orangepi-5-plus"
printf 'schema_version = 1\n' > "${TMP_DIR}/IMAGES/orangepi-5-plus-starry/manifest.toml"
(
    cd "${TMP_DIR}/IMAGES/orangepi-5-plus-starry"
    sha256sum orangepi-5-plus > SHA256SUMS
)

LOG_CREATE_DEFAULT_FILE=0 bash "${ROOT_DIR}/scripts/tools/pack.sh" \
    --in_dir "${TMP_DIR}/IMAGES" \
    --out_dir "${TMP_DIR}/release"

archive="${TMP_DIR}/release/orangepi-5-plus-starry.tar.xz"
[[ -f "${archive}" ]]
tar -tf "${archive}" | grep -q '^\./orangepi-5-plus$'
tar -tf "${archive}" | grep -q '^\./manifest.toml$'
tar -tf "${archive}" | grep -q '^\./SHA256SUMS$'

LOG_CREATE_DEFAULT_FILE=0 source "${ROOT_DIR}/scripts/tools/github.sh"
ASSET_DIR="${TMP_DIR}/release"
REGISTRY_DIR="${TMP_DIR}/registry"
REPO="rcore-os/tgosimages"
TAG="v9.9.9-test"
github_generate_registry "${REGISTRY_DIR}"

grep -q 'name = "orangepi-5-plus-starry"' "${REGISTRY_DIR}/${TAG}.toml"
grep -q 'description = "StarryOS for Orange Pi development board"' "${REGISTRY_DIR}/${TAG}.toml"
grep -q 'arch = "aarch64"' "${REGISTRY_DIR}/${TAG}.toml"

printf 'StarryOS release smoke test passed.\n'
