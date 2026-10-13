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

# Publication follows this build's target and retains its actual resolved lock.
publication_source="$work/publication-source"
mkdir -p "$publication_source"
git -C "$publication_source" init -q
printf 'target = "aarch64-unknown-linux-musl"\n' >"$publication_source/build.toml"
printf 'old-lock\n' >"$publication_source/Cargo.lock"
git -C "$publication_source" add build.toml Cargo.lock
git -C "$publication_source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
LOG_CREATE_DEFAULT_FILE=0 bash -c '
    set -euo pipefail
    source "$1/scripts/os/starry.sh"
    STARRY_SRC_DIR=$2 STARRY_SOURCE_PROVIDED=1 STARRY_CONFIG=build.toml
    STARRY_IMAGES_DIR=$3/images STARRY_RELEASE_IMAGES_DIR=$3/release
    CARGO_TARGET_DIR=$3/objects
    mkdir -p "$CARGO_TARGET_DIR/aarch64-unknown-none-softfloat/release"
    printf stale-bare >"$CARGO_TARGET_DIR/aarch64-unknown-none-softfloat/release/starryos.bin"
    ensure_musl_toolchain() { :; }
    build_cargo() {
        mkdir -p "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release"
        printf fresh-musl >"$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/starryos.bin"
        printf "resolved-lock\n" >"$STARRY_SRC_DIR/Cargo.lock"
    }
    starry_build
    [[ $(cat "$STARRY_IMAGES_DIR/orangepi-5-plus") == fresh-musl ]]
    [[ $(cat "$STARRY_SRC_DIR/Cargo.lock") == resolved-lock ]]
    expected=$(sha256sum "$STARRY_SRC_DIR/Cargo.lock"); expected=${expected%% *}
    grep -Fq "source_lock_sha256 = \"$expected\"" "$STARRY_RELEASE_IMAGES_DIR/manifest.toml"
' _ "$repo_root" "$publication_source" "$work/publication"

# Managed sources are disposable: staged/unstaged edits and extra files cannot
# block a rerun. Ignored compiler outputs still survive the normal Git clean.
printf 'user edit\n' >"$STARRY_SRC_DIR/value"
printf 'staged edit\n' >"$STARRY_SRC_DIR/other.toml"
git -C "$STARRY_SRC_DIR" add other.toml
printf extra >"$STARRY_SRC_DIR/extra-file"
mkdir -p "$STARRY_SRC_DIR/target"
printf object >"$STARRY_SRC_DIR/target/keep.o"
printf '/target/\n' >>"$STARRY_SRC_DIR/.git/info/exclude"
starry_prepare_source
[[ $(<"$STARRY_SRC_DIR/value") == updated ]]
[[ $(<"$STARRY_SRC_DIR/other.toml") == config ]]
[[ ! -e $STARRY_SRC_DIR/extra-file ]]
[[ $(<"$STARRY_SRC_DIR/target/keep.o") == object ]]
[[ -z $(git -C "$STARRY_SRC_DIR" diff --cached --name-only) ]]
starry_prepare_source
printf 'PASS: managed StarryOS source directly retries and preserves compiler outputs\n'

# Explicit caller source is used as-is, including its local edits.
STARRY_SOURCE_PROVIDED=1
printf 'caller edit\n' >"$STARRY_SRC_DIR/value"
printf extra >"$STARRY_SRC_DIR/caller-file"
starry_prepare_source
[[ $(<"$STARRY_SRC_DIR/value") == 'caller edit' ]]
[[ -e $STARRY_SRC_DIR/caller-file ]]
printf 'PASS: explicit StarryOS source remains unchanged\n'
