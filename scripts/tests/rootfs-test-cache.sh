#!/usr/bin/env bash
set -euo pipefail
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d /tmp/rootfs-test-cache.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
[[ -f $repo_root/scripts/rootfs-tests/lib/cache.sh ]] || fail 'artifact cache helper exists'
source "$repo_root/scripts/rootfs-tests/lib/cache.sh"
# Exercise real cache transactions; fake only the external Docker identity lookup.
real_repo=$repo_root
repo_root="$work/repo"
plugin_dir="$repo_root/scripts/rootfs-tests/plugins"
mkdir -p "$plugin_dir" "$repo_root/scripts/rootfs-tests/lib" "$repo_root/patches/rootfs-tests/demo" "$work/bin"
for file in lib/cache.sh lib/common.sh alpine-builder.sh alpine-builder-packages.txt build.sh plugins/demo.sh; do
    printf 'recipe v1\n' > "$repo_root/scripts/rootfs-tests/$file"
done
printf 'patch v1\n' > "$repo_root/patches/rootfs-tests/demo/fix.patch"
cat > "$repo_root/scripts/rootfs-tests/alpine-builder.sh" <<'EOF'
#!/usr/bin/env bash
printf 'test-builder\n'
EOF
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ $1 == image && $2 == inspect ]] || exit 1
printf '%s\n' "${TEST_IMAGE_ID:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
EOF
chmod +x "$repo_root/scripts/rootfs-tests/alpine-builder.sh" "$work/bin/docker"
export PATH="$work/bin:$PATH"
name=demo version=1 arch=x86_64 rootfs=alpine scope=guest platform=linux/amd64
source_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
build_root="$work/build"
export ROOTFS_TEST_CACHE=1
build_demo() {
    printf 'build\n' >> "$work/build-count"
    [[ ${FAIL_BUILD:-0} != 1 ]] || return 19
    if [[ ${FAIL_MID_BUILD:-0} == 1 ]]; then
        false
        touch "$work/continued-after-failure"
    fi
    mkdir -p "$output/bin"
    printf '%s\n' "$source_sha256" > "$output/bin/test with space"
    chmod 0751 "$output/bin/test with space"
    ln "$output/bin/test with space" "$output/bin/hardlink"
    ln -s 'test with space' "$output/bin/link"
    touch -d @1700000000 "$output/bin/test with space"
    [[ ${ROOTFS_TEST_CACHE:-1} == 0 || -n ${ROOTFS_TEST_OFFLINE_FIXTURE_DIR:-} ||
       -n ${ROOTFS_TEST_ALPINE_BUILDER:-} || $rootfs_test_builder_image == sha256:* ]] || return 20
}
run_build() (
    local output
    output=$(mktemp -d "$work/output.XXXXXX")
    rootfs_test_with_artifact_cache "$output" build_demo
    [[ $(cat "$output/bin/test with space") == "$source_sha256" ]]
    [[ $(stat -c %a "$output/bin/test with space") == 751 ]]
    [[ "$output/bin/test with space" -ef "$output/bin/hardlink" ]]
    [[ $(readlink "$output/bin/link") == 'test with space' ]]
    [[ $(stat -c %Y "$output/bin/test with space") == 1700000000 ]]
)
count() { wc -l < "$work/build-count"; }
run_build
run_build
[[ $(count) == 1 ]] || fail 'identical inputs compile only once'
echo 'ok - cache hit preserves payload, modes, links and timestamps'
for setting in source arch rootfs scope flags image recipe patch helper; do
    case $setting in
    source) source_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    arch) arch=aarch64; platform=linux/arm64/v8 ;;
    rootfs) rootfs=debian ;;
    scope) scope=outer ;;
    flags) export ALPINE_LTP_CFLAGS='-O3 -DVALUE="literal value"' ;;
    image) export TEST_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    recipe) printf 'changed\n' >> "$plugin_dir/demo.sh" ;;
    patch) printf 'changed\n' >> "$repo_root/patches/rootfs-tests/demo/fix.patch" ;;
    helper) printf 'changed\n' >> "$plugin_dir/../lib/common.sh" ;;
    esac
    before=$(count)
    run_build
    run_build
    [[ $(count) == $((before + 1)) ]] || fail "$setting invalidates cache"
    echo "ok - $setting invalidates cache"
done
before=$(count)
while IFS= read -r -d '' archive; do printf corrupt > "$archive"; done < <(find "$build_root/artifacts" -name payload.tar -print0)
run_build
[[ $(count) == $((before + 1)) ]] || fail 'corrupt artifact rebuilt'
echo 'ok - corrupt archive is rebuilt'
before=$(count)
ROOTFS_TEST_CACHE=0 run_build
ROOTFS_TEST_CACHE=0 run_build
[[ $(count) == $((before + 2)) ]] || fail 'disabled cache rebuilds'
echo 'ok - disabled cache bypasses lookup and publication'
# A failed producer must not publish an entry, and retry must really compile.
export ALPINE_LTP_CFLAGS=-O1
FAIL_BUILD=1 run_build > "$work/failure.log" 2>&1 & failed=$!
if wait "$failed"; then fail 'failed build succeeded'; fi
before=$(count)
run_build
[[ $(count) == $((before + 1)) ]] || fail 'failed build polluted cache'
[[ -z $(find "$build_root/artifacts" -name '.stage.*' -print -quit) ]] || fail 'failed transaction leaked staging'
echo 'ok - failed build is not cached and staging is cleaned'
export ALPINE_LTP_CFLAGS=-Os
before=$(count)
run_build > "$work/parallel-a.log" 2>&1 & first=$!
run_build > "$work/parallel-b.log" 2>&1 & second=$!
wait "$first"
wait "$second"
[[ $(count) == $((before + 1)) ]] || fail 'concurrent producers compiled twice'
echo 'ok - concurrent producers share one completed artifact'

export ALPINE_LTP_CFLAGS=-Og
FAIL_MID_BUILD=1 run_build > "$work/mid-failure.log" 2>&1 & failed=$!
if wait "$failed"; then fail 'mid-build failure succeeded'; fi
[[ ! -e $work/continued-after-failure ]] || fail 'callback lost errexit'
before=$(count)
run_build
[[ $(count) == $((before + 1)) ]] || fail 'mid-build failure polluted cache'
echo 'ok - intermediate recipe failures stop compilation and are not cached'

before=$(count)
ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$work/fixture" TEST_IMAGE_ID=invalid run_build
ROOTFS_TEST_ALPINE_BUILDER="$work/custom-builder" TEST_IMAGE_ID=invalid run_build
[[ $(count) == $((before + 2)) ]] || fail 'special build modes should bypass cache'
echo 'ok - fixtures and custom builders bypass Docker identity and artifact lookup'

before=$(count)
TEST_IMAGE_ID=invalid run_build > "$work/identity-failure.log" 2>&1 & failed=$!
if wait "$failed"; then fail 'mutable or missing image ID accepted'; fi
[[ $(count) == "$before" ]] || fail 'invalid builder identity reached compilation'
echo 'ok - missing immutable builder identity is rejected before compilation'

# Exercise an actual built-in plugin's parser, source validation, recipe and
# cache callback. Only Docker is substituted, compiling a tiny static fixture.
cp "$real_repo/scripts/rootfs-tests/plugins/iozone.sh" "$plugin_dir/iozone.sh"
cp "$real_repo/scripts/rootfs-tests/lib/"{common,cache}.sh "$plugin_dir/../lib/"
mkdir -p "$repo_root/scripts/lib"
cp "$real_repo/scripts/lib/build-lock.sh" "$repo_root/scripts/lib/"
mkdir -p "$work/fixture/iozone3_511/src/current"
printf 'int main(void) { return 0; }\n' > "$work/fixture/iozone3_511/src/current/tiny.c"
printf 'linux:\n\t$(CC) $(CFLAGS) tiny.c -o iozone $(LDFLAGS)\n' > "$work/fixture/iozone3_511/src/current/Makefile"
tar -czf "$work/iozone.tgz" -C "$work/fixture" iozone3_511
iozone_sum=$(sha256sum "$work/iozone.tgz" | awk '{print $1}')
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == image && $2 == inspect ]]; then
    printf '%s\n' "$TEST_IMAGE_ID"
    exit
fi
[[ $1 == run ]] || exit 2
shift
mount=
while (($#)); do
    case $1 in
    --rm) shift ;;
    --platform|-w) shift 2 ;;
    -v) mount=${2%:/work}; shift 2 ;;
    sha256:*) [[ $1 == "$TEST_IMAGE_ID" ]] || exit 3; break ;;
    *) exit 4 ;;
    esac
done
[[ -n $mount ]]
printf 'compile\n' >> "$TEST_COMPILE_LOG"
make -C "$mount" linux CC=cc CFLAGS='-O2 -static' LDFLAGS=-static
EOF
chmod +x "$work/bin/docker"
export TEST_COMPILE_LOG="$work/integration-compiles"
for iteration in 1 2; do
    mkdir "$work/integration-output-$iteration"
    IOZONE_SOURCE_URL="file://$work/iozone.tgz" IOZONE_SOURCE_SHA256="$iozone_sum" \
        ROOTFS_TEST_BUILD_ROOT="$work/integration-build" \
        bash "$plugin_dir/iozone.sh" build --arch x86_64 --rootfs alpine --scope guest \
        --output "$work/integration-output-$iteration"
    "$work/integration-output-$iteration/guest-tests/iozone/iozone"
done
[[ $(wc -l < "$TEST_COMPILE_LOG") == 1 ]] || fail 'built-in cache hit recompiled'
cmp "$work/integration-output-1/guest-tests/iozone/iozone" "$work/integration-output-2/guest-tests/iozone/iozone"
echo 'ok - built-in plugin reuses validated executable with the pinned builder ID'
mkdir "$work/invalid-source-output"
if IOZONE_SOURCE_URL="file://$work/iozone.tgz" ROOTFS_TEST_BUILD_ROOT="$work/integration-build" \
    bash "$plugin_dir/iozone.sh" build --arch x86_64 --rootfs alpine --scope guest \
    --output "$work/invalid-source-output" > "$work/invalid-source.log" 2>&1; then
    fail 'source validation was skipped by the cache'
fi
grep -q 'source URL and checksum overrides must be provided together' "$work/invalid-source.log"
echo 'ok - built-in source overrides are validated before cache lookup'

[[ -z $(find "$work" -type f -name '*.lock' -print -quit) ]] || {
    echo 'FAIL: completed operations leave lock files behind' >&2
    exit 1
}
