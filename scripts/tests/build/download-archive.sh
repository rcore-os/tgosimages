#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib/download-archive.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/source/package" "$work/output"
printf 'payload\n' > "$work/source/package/value"
tar -czf "$work/source.tar.gz" -C "$work/source" package

download_archive "file://$work/source.tar.gz" "$work/cache.tar.gz" "$work/output"
[[ $(<"$work/output/value") == payload ]]

mkdir -p "$work/bin" "$work/retry-output"
printf '%s\n' '#!/usr/bin/env bash' 'for ((i=1; i<=$#; i++)); do' \
    '  if [[ ${!i} == --output ]]; then j=$((i+1)); output=${!j}; fi' \
    'done' 'if [[ ! -e $RETRY_MARKER ]]; then' \
    '  touch "$RETRY_MARKER"; printf broken > "$output"; exit 0' \
    'fi' 'exec "$REAL_CURL" "$@"' > "$work/bin/curl"
chmod +x "$work/bin/curl"
REAL_CURL=$(command -v curl) RETRY_MARKER="$work/retried" PATH="$work/bin:$PATH" \
    download_archive "file://$work/source.tar.gz" "$work/retry.tar.gz" "$work/retry-output"
[[ $(<"$work/retry-output/value") == payload ]]
[[ -f $work/cache.tar.gz.sha256 ]]

rm -f -- "$work/source.tar.gz"
download_archive "file://$work/source.tar.gz" "$work/cache.tar.gz" "$work/output"
[[ $(<"$work/output/value") == payload ]]

tar -czf "$work/source.tar.gz" -C "$work/source" package
printf broken > "$work/cache.tar.gz"
download_archive "file://$work/source.tar.gz" "$work/cache.tar.gz" "$work/output"
[[ $(<"$work/output/value") == payload ]]
