#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)
work=$(mktemp -d /tmp/starry-source-preparation.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
upstream="$work/upstream"
mkdir -p "$upstream" "$work/workspace"
git -C "$upstream" init -q
git -C "$upstream" config user.name test
git -C "$upstream" config user.email test@example.com
printf 'base\n' >"$upstream/value"
printf 'config\n' >"$upstream/other.toml"
git -C "$upstream" add value other.toml
git -C "$upstream" commit -qm base
base=$(git -C "$upstream" rev-parse HEAD)

export BUILD_WORK_DIR="$work/workspace"
export BUILD_CACHE_DIR="$work/cache"
export STARRY_REPO_URL="$upstream"
export STARRY_REF="$base"
export LOG_CREATE_DEFAULT_FILE=0
source "$repo_root/scripts/os/starry.sh"
STARRY_CONFIG=other.toml

starry_prepare_source
[[ $(<"$STARRY_SRC_DIR/value") == base ]]
starry_prepare_source

git -C "$upstream" switch -qc dev
printf 'updated\n' >"$upstream/value"
git -C "$upstream" add value
git -C "$upstream" commit -qm updated
STARRY_REF=dev
starry_prepare_source
[[ $(<"$STARRY_SRC_DIR/value") == updated ]]

if STARRY_LOG=debug bash -c '
    set -euo pipefail
    source "$1/scripts/os/starry.sh"
    STARRY_CONFIG=other.toml
    ensure_musl_toolchain() { :; }
    build_cargo() { return 23; }
    starry_build
' _ "$repo_root"; then
    printf 'failing StarryOS build succeeded\n' >&2
    exit 1
fi
[[ ! -e $STARRY_SRC_DIR/.tgosimages-starry-other.toml ]]

printf 'user edit\n' >"$STARRY_SRC_DIR/value"
if starry_prepare_source; then
    printf 'edited StarryOS source cache was accepted\n' >&2
    exit 1
fi
[[ $(<"$STARRY_SRC_DIR/value") == 'user edit' ]]

printf 'PASS: StarryOS ref changes invalidate source and local edits are preserved\n'
