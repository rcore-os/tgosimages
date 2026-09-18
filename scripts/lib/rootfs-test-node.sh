#!/usr/bin/env bash
set -euo pipefail
output=$1
shift
mkdir -p -- "$(dirname -- "$output")"
exec "$@" --output "$output"
