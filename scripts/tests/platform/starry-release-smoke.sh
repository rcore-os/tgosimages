#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../../.." && pwd -P)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

LOG_CREATE_DEFAULT_FILE=0 bash -c '
    source "$1/scripts/os/starry.sh"
    [[ $STARRY_REF == dev ]]
    starry_parse_args --ref custom-ref
    [[ $STARRY_REF == custom-ref ]]
' _ "$ROOT_DIR"

# An explicitly supplied checkout keeps its revision and local fixes.
source_fixture="$TMP_DIR/source"
git init -q -b dev "$source_fixture"
printf 'baseline\n' > "$source_fixture/local.txt"
git -C "$source_fixture" add local.txt
git -C "$source_fixture" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm baseline
git -C "$source_fixture" remote add origin "$source_fixture"
printf 'local fix\n' > "$source_fixture/local.txt"
LOG_CREATE_DEFAULT_FILE=0 bash -c '
    source "$1/scripts/os/starry.sh"
    STARRY_REPO_URL="$2"
    starry_parse_args --src-dir "$2"
    before=$(git -C "$2" rev-parse HEAD)
    starry_prepare_source
    [[ $(git -C "$2" rev-parse HEAD) == "$before" ]]
    [[ $(cat "$2/local.txt") == "local fix" ]]
' _ "$ROOT_DIR" "$source_fixture"

mkdir -p "${TMP_DIR}/IMAGES/orangepi/starry"
printf 'test-starry-image\n' > "${TMP_DIR}/IMAGES/orangepi/starry/orangepi-5-plus"
printf 'schema_version = 1\n' > "${TMP_DIR}/IMAGES/orangepi/starry/manifest.toml"
(
    cd "${TMP_DIR}/IMAGES/orangepi/starry"
    sha256sum orangepi-5-plus > SHA256SUMS
)

LOG_CREATE_DEFAULT_FILE=0 bash "${ROOT_DIR}/scripts/tools/pack.sh" \
    --in_dir "${TMP_DIR}/IMAGES" \
    --out_dir "${TMP_DIR}/release"

archive="${TMP_DIR}/release/orangepi.tar.xz"
[[ -f "${archive}" ]]
tar -tf "${archive}" | grep -q '^\./starry/orangepi-5-plus$'
tar -tf "${archive}" | grep -q '^\./starry/manifest.toml$'
tar -tf "${archive}" | grep -q '^\./starry/SHA256SUMS$'

LOG_CREATE_DEFAULT_FILE=0 source "${ROOT_DIR}/scripts/tools/github.sh"
ASSET_DIR="${TMP_DIR}/release"
REGISTRY_DIR="${TMP_DIR}/registry"
REPO="rcore-os/tgosimages"
TAG="v9.9.9-test"
github_generate_registry "${REGISTRY_DIR}"

grep -q 'name = "orangepi"' "${REGISTRY_DIR}/${TAG}.toml"
grep -q 'description = "Guest image bundle for Orange Pi development board"' "${REGISTRY_DIR}/${TAG}.toml"
grep -q 'arch = "aarch64"' "${REGISTRY_DIR}/${TAG}.toml"

printf 'StarryOS release smoke test passed.\n'
