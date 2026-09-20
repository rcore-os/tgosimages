#!/usr/bin/env bash
set -euo pipefail

sdk_dir=$1
shift
if ! command -v python2 >/dev/null 2>&1 || ! command -v python >/dev/null 2>&1; then
    python3_path=$(command -v python3) || {
        printf 'Firefly SDK requires Python 2 or Python 3\n' >&2
        exit 127
    }
    python2_shim_dir=$(mktemp -d "${TMPDIR:-/tmp}/tgosimages-python2.XXXXXX")
    trap 'rm -f -- "$python2_shim_dir/python2" "$python2_shim_dir/python"; rmdir -- "$python2_shim_dir"' EXIT
    if ! command -v python2 >/dev/null 2>&1; then
        ln -s -- "$python3_path" "$python2_shim_dir/python2"
    fi
    if ! command -v python >/dev/null 2>&1; then
        ln -s -- "$python3_path" "$python2_shim_dir/python"
    fi
    export PATH="$python2_shim_dir:$PATH"
fi

cd "$sdk_dir"
./build.sh firefly_rk3568_roc-rk3568-pc_ubuntu_defconfig
./build.sh "$@"
