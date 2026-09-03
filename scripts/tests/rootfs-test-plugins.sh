#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_script="$repo_root/scripts/rootfs-tests/build.sh"
common_script="$repo_root/scripts/rootfs-tests/lib/common.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

real_find=$(command -v find)
real_mv=$(command -v mv)
real_curl=$(command -v curl)
real_tar=$(command -v tar)
fault_bin="$work/fault-bin"
mkdir "$fault_bin"
cat >"$fault_bin/find" <<EOF
#!/usr/bin/env bash
case \${FAIL_FIND_MODE:-} in
discovery) exit 42 ;;
inventory)
    for argument in "\$@"; do
        [[ \$argument == -maxdepth ]] && exec "$real_find" "\$@"
    done
    exit 43
    ;;
esac
exec "$real_find" "\$@"
EOF
cat >"$fault_bin/mv" <<EOF
#!/usr/bin/env bash
source_path=\${@: -2:1}
destination=\${@: -1}
if [[ -n \${FAULT_MV_OUTPUT:-} && \$source_path == "\$FAULT_MV_OUTPUT.tmp."* &&
      \$destination == "\$FAULT_MV_OUTPUT" ]]; then
    exit 44
fi
exec "$real_mv" "\$@"
EOF
cat >"$fault_bin/curl" <<EOF
#!/usr/bin/env bash
if [[ \${INTERRUPT_CURL:-} == 1 ]]; then
    kill -TERM \$PPID
    exit 143
fi
exec "$real_curl" "\$@"
EOF
cat >"$fault_bin/tar" <<EOF
#!/usr/bin/env bash
if [[ \${INTERRUPT_TAR:-} == 1 ]]; then
    kill -TERM \$PPID
    exit 143
fi
exec "$real_tar" "\$@"
EOF
chmod +x "$fault_bin/find" "$fault_bin/mv" "$fault_bin/curl" "$fault_bin/tar"

tests=0

fail() {
    echo "not ok $tests - $*" >&2
    exit 1
}

pass() {
    echo "ok $tests - $*"
}

assert_eq() {
    local expected=$1 actual=$2 message=$3
    [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_exists() {
    [[ -e "$1" || -L "$1" ]] || fail "$2 (missing $1)"
}

run_ok() {
    local message=$1
    shift
    tests=$((tests + 1))
    if ! "$@" >"$work/stdout" 2>"$work/stderr"; then
        sed -n '1,120p' "$work/stderr" >&2
        fail "$message"
    fi
    pass "$message"
}

run_fail() {
    local message=$1
    shift
    tests=$((tests + 1))
    if "$@" >"$work/stdout" 2>"$work/stderr"; then
        fail "$message (command unexpectedly succeeded)"
    fi
    pass "$message"
}

new_plugins() {
    plugins=$(mktemp -d "$work/plugins.XXXXXX")
}

make_plugin() {
    local file=$1 name=$2 arches=$3 rootfs=$4 scopes=$5 body=$6
    cat >"$plugins/$file.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case \${1-} in
describe)
    printf '%s\\n' 'name=$name' 'arches=$arches' 'rootfs=$rootfs' 'scopes=$scopes'
    ;;
build)
    shift
    arch= rootfs= scope= output=
    while (( \$# )); do
        case \$1 in
        --arch) arch=\$2; shift 2 ;;
        --rootfs) rootfs=\$2; shift 2 ;;
        --scope) scope=\$2; shift 2 ;;
        --output) output=\$2; shift 2 ;;
        *) exit 64 ;;
        esac
    done
    [[ -n \$arch && -n \$rootfs && -n \$scope && -n \$output ]]
    [[ -z \${FAKE_EXPECT_ARCH:-} || \$arch == \$FAKE_EXPECT_ARCH ]]
    [[ -z \${FAKE_EXPECT_ROOTFS:-} || \$rootfs == \$FAKE_EXPECT_ROOTFS ]]
    [[ -z \${FAKE_EXPECT_SCOPE:-} || \$scope == \$FAKE_EXPECT_SCOPE ]]
    if [[ -n \${FAKE_PLUGIN_ARGS_LOG:-} ]]; then
        printf '%s|%s|%s|%s\\n' '$name' "\$arch" "\$rootfs" "\$scope" >>"\$FAKE_PLUGIN_ARGS_LOG"
    fi
    $body
    ;;
*) exit 64 ;;
esac
EOF
    chmod +x "$plugins/$file.sh"
}

build() {
    ROOTFS_TEST_PLUGIN_DIR=$plugins bash "$build_script" build "$@"
}

# Explicit selection merges outputs and de-duplicates names.
new_plugins
make_plugin fake-a fake-a 'aarch64,x86_64' 'alpine,debian' 'outer,guest' \
    'mkdir -p "$output/guest-tests"; printf a >"$output/guest-tests/a"'
make_plugin fake-b fake-b aarch64 alpine outer \
    'mkdir -p "$output/guest-tests"; printf b >"$output/guest-tests/b"'
overlay="$work/explicit"
run_ok 'explicit plugins merge filesystem-rooted overlays' \
    build --arch aarch64 --rootfs alpine --scope outer --tests fake-a,fake-b --output "$overlay"
assert_exists "$overlay/guest-tests/a" 'first explicit plugin output is published'
assert_exists "$overlay/guest-tests/b" 'second explicit plugin output is published'

counter="$work/count"
make_plugin counted counted aarch64 alpine outer \
    "printf x >>'$counter'; mkdir -p \"\$output/guest-tests\"; printf counted >\"\$output/guest-tests/counted\""
run_ok 'duplicate selections execute once' \
    build --arch aarch64 --rootfs alpine --scope outer --tests counted,counted --output "$work/dedup"
assert_eq x "$(cat "$counter")" 'duplicate plugin ran exactly once'

new_plugins
make_plugin forwarded forwarded riscv64 debian guest \
    'mkdir -p "$output/guest-tests"; : >"$output/guest-tests/forwarded"'
run_ok 'build forwards the exact requested plugin context' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" FAKE_EXPECT_ARCH=riscv64 \
        FAKE_EXPECT_ROOTFS=debian FAKE_EXPECT_SCOPE=guest FAKE_PLUGIN_ARGS_LOG="$work/args-log" \
        bash "$build_script" build --arch riscv64 --rootfs debian --scope guest \
        --tests forwarded --output "$work/forwarded"
assert_eq 'forwarded|riscv64|debian|guest' "$(cat "$work/args-log")" \
    'plugin received exact arch, rootfs, and scope values'

new_plugins
make_plugin empty-a empty-a aarch64 alpine outer \
    '[[ -z $(find "$output" -mindepth 1 -print -quit) ]]; printf "%s\n" "$output" >>"$FAKE_OUTPUT_LOG"; : >"$output/a"'
make_plugin empty-b empty-b aarch64 alpine outer \
    '[[ -z $(find "$output" -mindepth 1 -print -quit) ]]; printf "%s\n" "$output" >>"$FAKE_OUTPUT_LOG"; : >"$output/b"'
run_ok 'plugins receive distinct initially empty output directories' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" FAKE_OUTPUT_LOG="$work/output-log" \
        bash "$build_script" build --arch aarch64 --rootfs alpine --scope outer \
        --tests empty-a,empty-b --output "$work/empty-stages"
assert_eq 2 "$(sort -u "$work/output-log" | wc -l)" 'plugin output directories are distinct'

# Capability handling for all and explicit selections.
new_plugins
make_plugin compatible compatible aarch64 alpine guest \
    'mkdir -p "$output/guest-tests"; : >"$output/guest-tests/compatible"'
make_plugin wrong-arch wrong-arch x86_64 alpine guest \
    'mkdir -p "$output/guest-tests"; : >"$output/guest-tests/wrong-arch"'
make_plugin wrong-rootfs wrong-rootfs aarch64 debian guest \
    'mkdir -p "$output/guest-tests"; : >"$output/guest-tests/wrong-rootfs"'
run_ok 'all selects only capability-compatible plugins' \
    build --arch aarch64 --rootfs alpine --scope guest --tests all --output "$work/all"
assert_exists "$work/all/guest-tests/compatible" 'compatible all plugin ran'
[[ ! -e "$work/all/guest-tests/wrong-arch" ]] || fail 'all ran wrong-arch plugin'
[[ ! -e "$work/all/guest-tests/wrong-rootfs" ]] || fail 'all ran wrong-rootfs plugin'
run_fail 'explicit unsupported plugin is rejected' \
    build --arch aarch64 --rootfs alpine --scope guest --tests wrong-arch --output "$work/unsupported"
run_fail 'unknown plugin is rejected' \
    build --arch aarch64 --rootfs alpine --scope guest --tests absent --output "$work/unknown"
run_ok 'none publishes an empty overlay' \
    build --arch aarch64 --rootfs alpine --scope guest --tests none --output "$work/none"
[[ -d "$work/none" ]] || fail 'none did not publish a directory'
[[ -z $(find "$work/none" -mindepth 1 -print -quit) ]] || fail 'none overlay was not empty'

# Strict describe parsing and declared-name uniqueness.
new_plugins
cat >"$plugins/missing.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=missing' 'arches=aarch64' 'rootfs=alpine'
EOF
chmod +x "$plugins/missing.sh"
run_fail 'describe missing a required key is rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/missing"

new_plugins
cat >"$plugins/unknown-key.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=unknown-key' 'arches=aarch64' 'rootfs=alpine' 'scopes=outer' 'extra=nope'
EOF
chmod +x "$plugins/unknown-key.sh"
run_fail 'describe unknown keys are rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/unknown-key"

new_plugins
cat >"$plugins/duplicate-key.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=duplicate-key' 'arches=aarch64' 'rootfs=alpine' 'rootfs=debian'
EOF
chmod +x "$plugins/duplicate-key.sh"
run_fail 'describe duplicate keys are rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/duplicate-key"

new_plugins
make_plugin bad-arches bad-arches 'aarch64,garbage' alpine outer ':'
run_fail 'describe rejects unknown arch capability members' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/bad-arches"
new_plugins
make_plugin bad-rootfs bad-rootfs aarch64 'alpine,garbage' outer ':'
run_fail 'describe rejects unknown rootfs capability members' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/bad-rootfs"
new_plugins
make_plugin bad-scopes bad-scopes aarch64 alpine 'outer,garbage' ':'
run_fail 'describe rejects unknown scope capability members' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/bad-scopes"
new_plugins
make_plugin duplicate-arches duplicate-arches 'aarch64,aarch64' alpine outer ':'
run_fail 'describe rejects duplicate arch capability members' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/duplicate-arches"
new_plugins
make_plugin duplicate-rootfs duplicate-rootfs aarch64 'alpine,alpine' outer ':'
run_fail 'describe rejects duplicate rootfs capability members' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/duplicate-rootfs"
new_plugins
make_plugin empty-scope empty-scope aarch64 alpine 'outer,' ':'
run_fail 'describe rejects empty scope capability members' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/empty-scope"

new_plugins
cat >"$plugins/failed-describe.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=failed-describe' 'arches=aarch64' 'rootfs=alpine' 'scopes=outer'
exit 1
EOF
chmod +x "$plugins/failed-describe.sh"
run_fail 'a failed describe command is rejected' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
metadata_tmp="$work/metadata-tmp"
mkdir "$metadata_tmp"
run_fail 'describe failure cleans its metadata temporary file' \
    env TMPDIR="$metadata_tmp" ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
[[ -z $(find "$metadata_tmp" -mindepth 1 -print -quit) ]] || fail 'describe failure leaked metadata temp'

new_plugins
cat >"$plugins/signalled.sh" <<EOF
#!/usr/bin/env bash
kill -TERM \$PPID
exit 1
EOF
chmod +x "$plugins/signalled.sh"
signal_tmp="$work/signal-tmp"
mkdir "$signal_tmp"
run_fail 'signal during describe cleans its metadata temporary file' \
    env TMPDIR="$signal_tmp" ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
[[ -z $(find "$signal_tmp" -mindepth 1 -print -quit) ]] || fail 'signal during describe leaked metadata temp'

new_plugins
make_plugin one same aarch64 alpine outer ':'
make_plugin two same aarch64 alpine outer ':'
run_fail 'duplicate declared plugin names are rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests all --output "$work/duplicate-name"

# Merge inventory permits shared directories, but no other path/type collision.
new_plugins
make_plugin dir-a dir-a aarch64 alpine outer \
    'mkdir -p "$output/guest-tests/a"; : >"$output/guest-tests/a/file"'
make_plugin dir-b dir-b aarch64 alpine outer \
    'mkdir -p "$output/guest-tests/b"; : >"$output/guest-tests/b/file"'
run_ok 'directory-directory overlap is allowed' \
    build --arch aarch64 --rootfs alpine --scope outer --tests dir-a,dir-b --output "$work/shared-dir"

new_plugins
make_plugin unusual-paths unusual-paths aarch64 alpine outer \
    'mkdir -p "$output/dir with space"; : >"$output/dir with space/-leading[glob]"; newline_name=$'"'"'line\nbreak'"'"'; : >"$output/$newline_name"'
unusual_output="$work/output with space/-overlay[glob]"
mkdir -p "$(dirname -- "$unusual_output")"
run_ok 'NUL-safe inventory preserves unusual path names' \
    build --arch aarch64 --rootfs alpine --scope outer --tests unusual-paths --output "$unusual_output"
assert_exists "$unusual_output/dir with space/-leading[glob]" 'space, glob, and leading-dash path survived'
assert_exists "$unusual_output/"$'line\nbreak' 'newline path survived'

new_plugins
make_plugin file-a file-a aarch64 alpine outer 'mkdir -p "$output/x"; : >"$output/x/file"'
make_plugin file-b file-b aarch64 alpine outer 'mkdir -p "$output/x"; : >"$output/x/file"'
run_fail 'duplicate files are rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests file-a,file-b --output "$work/file-collision"

inventory_tmp="$work/inventory-tmp"
mkdir "$inventory_tmp"
run_fail 'inventory producer failure cannot bypass collision checks or publish' \
    env PATH="$fault_bin:$PATH" TMPDIR="$inventory_tmp" FAIL_FIND_MODE=inventory ROOTFS_TEST_PLUGIN_DIR="$plugins" \
        bash "$build_script" build --arch aarch64 --rootfs alpine --scope outer \
        --tests file-a,file-b --output "$work/failed-inventory"
[[ ! -e $work/failed-inventory && ! -L $work/failed-inventory ]] ||
    fail 'inventory failure published an unchecked overlay'
[[ -z $(find "$inventory_tmp" -mindepth 1 -print -quit) ]] || fail 'inventory failure leaked owned temporary files'

new_plugins
make_plugin link-a link-a aarch64 alpine outer 'mkdir -p "$output/x"; ln -s first "$output/x/link"'
make_plugin link-b link-b aarch64 alpine outer 'mkdir -p "$output/x"; ln -s second "$output/x/link"'
run_fail 'duplicate symlinks are rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests link-a,link-b --output "$work/link-collision"

new_plugins
make_plugin plain plain aarch64 alpine outer 'mkdir -p "$output/x"; : >"$output/x/node"'
make_plugin directory directory aarch64 alpine outer 'mkdir -p "$output/x/node"'
run_fail 'file-directory conflicts are rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests plain,directory --output "$work/type-collision"

new_plugins
make_plugin blocker blocker aarch64 alpine outer 'mkdir -p "$output/x"; ln -s target "$output/x/node"'
make_plugin descendant descendant aarch64 alpine outer 'mkdir -p "$output/x/node"; : >"$output/x/node/child"'
run_fail 'file or symlink blocking another plugin descendant is rejected' \
    build --arch aarch64 --rootfs alpine --scope outer --tests blocker,descendant --output "$work/ancestor-collision"

mkdir -p "$work/preserved"
printf keep >"$work/preserved/original"
run_fail 'failed builds do not partially replace output' \
    build --arch aarch64 --rootfs alpine --scope outer --tests blocker,descendant --output "$work/preserved"
assert_eq keep "$(cat "$work/preserved/original")" 'existing output survived failed build'

new_plugins
atomic_log="$work/atomic-log"
make_plugin atomic-a atomic-a aarch64 alpine outer \
    'printf a >>"$ATOMIC_LOG"; mkdir -p "$output/x"; : >"$output/x/same"'
make_plugin atomic-b atomic-b aarch64 alpine outer \
    'printf b >>"$ATOMIC_LOG"; mkdir -p "$output/x"; : >"$output/x/same"'
mkdir -p "$work/published"
printf original >"$work/published/content"
run_fail 'a later collision leaves an existing published output untouched' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" ATOMIC_LOG="$atomic_log" \
        bash "$build_script" build --arch aarch64 --rootfs alpine --scope outer \
        --tests atomic-a,atomic-b --output "$work/published"
assert_eq ab "$(cat "$atomic_log")" 'both plugins ran before the later collision failed'
assert_eq original "$(cat "$work/published/content")" 'published output content was untouched'
[[ -z $(find "$work/published" -mindepth 1 ! -name content -print -quit) ]] ||
    fail 'failed build partially changed the published output'
if compgen -G "$work/published.tmp.*" >/dev/null; then
    fail 'failed build left a temporary publish directory'
fi

new_plugins
make_plugin fails-late fails-late aarch64 alpine outer 'exit 23'
run_fail 'a plugin failure leaves no partial new output' \
    build --arch aarch64 --rootfs alpine --scope outer --tests fails-late --output "$work/not-published"
[[ ! -e $work/not-published && ! -L $work/not-published ]] || fail 'failed build published partial output'
if compgen -G "$work/not-published.tmp.*" >/dev/null; then
    fail 'plugin failure left a temporary publish directory'
fi

new_plugins
make_plugin replacement replacement aarch64 alpine outer \
    'mkdir -p "$output/new"; printf complete >"$output/new/content"'
mkdir -p "$work/replaced/old"
printf stale >"$work/replaced/old/content"
run_ok 'successful publication atomically replaces an existing output' \
    build --arch aarch64 --rootfs alpine --scope outer --tests replacement --output "$work/replaced"
assert_eq complete "$(cat "$work/replaced/new/content")" 'replacement published the complete candidate'
[[ ! -e $work/replaced/old ]] || fail 'replacement retained stale output content'
if compgen -G "$work/replaced.old.*" >/dev/null || compgen -G "$work/replaced.tmp.*" >/dev/null; then
    fail 'replacement left backup or publish temporary directories'
fi

new_plugins
make_plugin rollback rollback aarch64 alpine outer \
    'mkdir -p "$output/new"; printf candidate >"$output/new/content"'
mkdir -p "$work/rollback-output/original"
printf preserved >"$work/rollback-output/original/content"
run_fail 'failed candidate install rolls the owned backup back' \
    env PATH="$fault_bin:$PATH" FAULT_MV_OUTPUT="$work/rollback-output" \
        ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" build \
        --arch aarch64 --rootfs alpine --scope outer --tests rollback \
        --output "$work/rollback-output"
assert_eq preserved "$(cat "$work/rollback-output/original/content")" 'rollback restored original output'
[[ ! -e $work/rollback-output/new ]] || fail 'failed candidate remained after rollback'
if compgen -G "$work/rollback-output.old.*" >/dev/null ||
   compgen -G "$work/rollback-output.tmp.*" >/dev/null; then
    fail 'rollback left candidate or backup residue'
fi

new_plugins
sync_dir="$work/publication-sync"
mkdir "$sync_dir"
make_plugin concurrent-a concurrent-a aarch64 alpine outer \
    'touch "$SYNC_DIR/a"; while [[ ! -e "$SYNC_DIR/b" ]]; do sleep 0.01; done; mkdir -p "$output/result"; printf a >"$output/result/a"'
make_plugin concurrent-b concurrent-b aarch64 alpine outer \
    'touch "$SYNC_DIR/b"; while [[ ! -e "$SYNC_DIR/a" ]]; do sleep 0.01; done; mkdir -p "$output/result"; printf b >"$output/result/b"'
tests=$((tests + 1))
env ROOTFS_TEST_PLUGIN_DIR="$plugins" SYNC_DIR="$sync_dir" timeout 10 bash "$build_script" build \
    --arch aarch64 --rootfs alpine --scope outer --tests concurrent-a --output "$work/concurrent" \
    >"$work/concurrent-a.out" 2>"$work/concurrent-a.err" &
pid_a=$!
env ROOTFS_TEST_PLUGIN_DIR="$plugins" SYNC_DIR="$sync_dir" timeout 10 bash "$build_script" build \
    --arch aarch64 --rootfs alpine --scope outer --tests concurrent-b --output "$work/concurrent" \
    >"$work/concurrent-b.out" 2>"$work/concurrent-b.err" &
pid_b=$!
status_a=0; wait "$pid_a" || status_a=$?
status_b=0; wait "$pid_b" || status_b=$?
[[ $status_a == 0 && $status_b == 0 ]] || fail "concurrent publications failed ($status_a, $status_b)"
pass 'concurrent same-output publications serialize successfully'
published_files=$(find "$work/concurrent/result" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
[[ $published_files == a || $published_files == b ]] || fail 'concurrent output was not exactly one complete result'
if find "$work/concurrent" -mindepth 1 -type d -name '*.tmp.*' -print -quit | grep -q .; then
    fail 'concurrent publication nested a temporary directory in output'
fi
if compgen -G "$work/concurrent.tmp.*" >/dev/null || compgen -G "$work/concurrent.old.*" >/dev/null; then
    fail 'concurrent publication left temporary or backup directories'
fi

# Framework-owned defaults and deterministic listing.
new_plugins
make_plugin zed zed aarch64 alpine outer ':'
make_plugin alpha alpha aarch64 alpine outer ':'
run_ok 'list reports compatible plugin names' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" list --arch aarch64 --rootfs alpine --scope outer
assert_eq $'alpha\nzed' "$(cat "$work/stdout")" 'list output is sorted'

new_plugins
make_plugin alpha alpha aarch64 alpine outer ':'
make_plugin z-last z-last x86_64 alpine outer ':'
run_ok 'list succeeds when its lexicographically last plugin is incompatible' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
assert_eq alpha "$(cat "$work/stdout")" 'list retained compatible output while filtering its last plugin'

new_plugins
make_plugin direct direct aarch64 alpine outer ':'
cp "$plugins/direct.sh" "$plugins/non-executable.sh"
chmod -x "$plugins/non-executable.sh"
cp "$plugins/direct.sh" "$plugins/no-sh-suffix"
chmod +x "$plugins/no-sh-suffix"
mkdir "$plugins/nested"
cp "$plugins/direct.sh" "$plugins/nested/nested.sh"
chmod +x "$plugins/nested/nested.sh"
run_ok 'discovery accepts only executable direct-child sh files' \
    env ROOTFS_TEST_PLUGIN_DIR="$plugins" bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
assert_eq direct "$(cat "$work/stdout")" 'discovery ignored non-executable, nested, and non-sh files'

discovery_tmp="$work/discovery-tmp"
mkdir "$discovery_tmp"
run_fail 'discovery producer failure is reported' \
    env PATH="$fault_bin:$PATH" TMPDIR="$discovery_tmp" FAIL_FIND_MODE=discovery ROOTFS_TEST_PLUGIN_DIR="$plugins" \
        bash "$build_script" list --arch aarch64 --rootfs alpine --scope outer
[[ -z $(find "$discovery_tmp" -mindepth 1 -print -quit) ]] || fail 'discovery failure leaked owned temporary files'

run_ok 'default plugin directory discovery succeeds' \
    env -u ROOTFS_TEST_PLUGIN_DIR bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
default_listing=$(cat "$work/stdout")
run_ok 'explicit repo plugin directory matches the default' \
    env ROOTFS_TEST_PLUGIN_DIR="$repo_root/scripts/rootfs-tests/plugins" bash "$build_script" list \
        --arch aarch64 --rootfs alpine --scope outer
assert_eq "$default_listing" "$(cat "$work/stdout")" 'default plugin directory resolves below the framework'

run_fail 'invalid arch is rejected' bash "$build_script" list \
    --arch armv7 --rootfs alpine --scope outer
run_fail 'invalid rootfs is rejected' bash "$build_script" list \
    --arch aarch64 --rootfs ubuntu --scope outer
run_fail 'invalid scope is rejected' bash "$build_script" list \
    --arch aarch64 --rootfs alpine --scope host

for case in 'alpine outer ltp' 'busybox outer none' 'debian outer none' \
            'busybox guest cyclictest,lmbench,iozone' \
            'alpine guest cyclictest,lmbench,iozone' \
            'debian guest cyclictest,lmbench,iozone'; do
    read -r rootfs scope expected <<<"$case"
    run_ok "defaults resolve $rootfs $scope" bash "$build_script" defaults --rootfs "$rootfs" --scope "$scope"
    assert_eq "$expected" "$(cat "$work/stdout")" "defaults value for $rootfs $scope"
done

# Shared helpers use exact CSV membership, stable mappings, and local files only.
tests=$((tests + 1))
# shellcheck source=/dev/null
source "$common_script"
rootfs_test_csv_contains alpine busybox,alpine,debian || fail 'CSV exact member was not found'
! rootfs_test_csv_contains pine busybox,alpine,debian || fail 'CSV helper accepted a substring'
assert_eq 'AArch64' "$(rootfs_test_expected_machine aarch64)" 'aarch64 ELF machine mapping'
assert_eq 'aarch64-linux-gnu-' "$(rootfs_test_cross_prefix aarch64)" 'aarch64 cross prefix mapping'
pass 'common CSV and architecture helpers work'

printf 'local payload' >"$work/source"
sum=$(sha256sum "$work/source" | awk '{print $1}')
tests=$((tests + 1))
rootfs_test_download_checked "file://$work/source" "$sum" "$work/downloaded" || fail 'checked local file download failed'
assert_eq 'local payload' "$(cat "$work/downloaded")" 'downloaded local file contents'
pass 'download helper verifies a local file checksum'

run_fail 'download helper rejects a bad checksum' \
    rootfs_test_download_checked "file://$work/source" \
        0000000000000000000000000000000000000000000000000000000000000000 "$work/bad-download"

download_tmp="$work/download-tmp"
mkdir "$download_tmp"
run_fail 'download helper cleans temporary files after a copy error' \
    env TMPDIR="$download_tmp" bash -c 'source "$1"; rootfs_test_download_checked file:///absent "$2" "$3"' \
        _ "$common_script" "$sum" "$work/copy-error"
[[ -z $(find "$work" -maxdepth 1 -name 'copy-error.tmp.*' -print -quit) ]] || fail 'copy error leaked adjacent temp'

tests=$((tests + 1))
interrupt_status=0
env PATH="$fault_bin:$PATH" INTERRUPT_CURL=1 bash -c \
    'source "$1"; rootfs_test_download_checked https://invalid.example/source "$2" "$3"' \
    _ "$common_script" "$sum" "$work/interrupted-download" \
    >"$work/stdout" 2>"$work/stderr" || interrupt_status=$?
assert_eq 143 "$interrupt_status" 'interrupted download preserves TERM status'
[[ -z $(find "$work" -maxdepth 1 -name 'interrupted-download.tmp.*' -print -quit) ]] ||
    fail 'interrupted download leaked adjacent temp'
pass 'download helper cleans its adjacent temp when interrupted'

mkdir "$work/directory-destination"
printf keep >"$work/directory-destination/content"
run_fail 'download helper rejects a directory destination' \
    rootfs_test_download_checked "file://$work/source" "$sum" "$work/directory-destination"
assert_eq keep "$(cat "$work/directory-destination/content")" 'directory destination stayed untouched'

printf first >"$work/source-a"
printf second >"$work/source-b"
sum_a=$(sha256sum "$work/source-a" | awk '{print $1}')
sum_b=$(sha256sum "$work/source-b" | awk '{print $1}')
tests=$((tests + 1))
rootfs_test_download_checked "file://$work/source-a" "$sum_a" "$work/concurrent-download" &
download_a=$!
rootfs_test_download_checked "file://$work/source-b" "$sum_b" "$work/concurrent-download" &
download_b=$!
download_status_a=0; wait "$download_a" || download_status_a=$?
download_status_b=0; wait "$download_b" || download_status_b=$?
[[ $download_status_a == 0 && $download_status_b == 0 ]] || fail 'concurrent checked downloads failed'
downloaded=$(cat "$work/concurrent-download")
[[ $downloaded == first || $downloaded == second ]] || fail 'concurrent download published partial contents'
[[ -z $(find "$work" -maxdepth 1 -name 'concurrent-download.tmp.*' -print -quit) ]] || fail 'concurrent download leaked temp'
pass 'download helper safely publishes concurrent calls'

host_arch=$(uname -m)
case $host_arch in
x86_64|aarch64|riscv64|loongarch64)
    run_ok 'ELF validator accepts a matching local executable' rootfs_test_validate_elf "$host_arch" /bin/sh
    wrong_arch=x86_64
    [[ $host_arch == x86_64 ]] && wrong_arch=aarch64
    run_fail 'ELF validator rejects a mismatched architecture' rootfs_test_validate_elf "$wrong_arch" /bin/sh
    ;;
esac

# The built-in guest plugins expose stable metadata and can build from checked,
# deliberately tiny offline source archives without contacting the network.
builtin_plugins="$repo_root/scripts/rootfs-tests/plugins"
for plugin in cyclictest lmbench iozone; do
    run_ok "$plugin describes its guest-only capabilities" "$builtin_plugins/$plugin.sh" describe
    assert_eq "name=$plugin
arches=aarch64,riscv64,x86_64,loongarch64
rootfs=busybox,alpine,debian
scopes=guest" "$(cat "$work/stdout")" "$plugin metadata"
done
run_ok 'lmbench real launcher smoke is explicitly bounded' grep -F 'timeout 15' "$builtin_plugins/lmbench.sh"

run_ok 'ltp describes its Alpine outer-only capabilities' "$builtin_plugins/ltp.sh" describe
assert_eq 'name=ltp
arches=aarch64,riscv64,x86_64,loongarch64
rootfs=alpine
scopes=outer' "$(cat "$work/stdout")" 'ltp metadata'
run_fail 'ltp rejects guest selection through the framework' \
    bash "$build_script" build --arch x86_64 --rootfs alpine --scope guest \
        --tests ltp --output "$work/unsupported-ltp-guest"
run_fail 'ltp rejects BusyBox selection through the framework' \
    bash "$build_script" build --arch x86_64 --rootfs busybox --scope outer \
        --tests ltp --output "$work/unsupported-ltp-busybox"
run_fail 'ltp rejects Debian selection through the framework' \
    bash "$build_script" build --arch x86_64 --rootfs debian --scope outer \
        --tests ltp --output "$work/unsupported-ltp-debian"

mkdir "$work/no-ltp-images"
run_fail 'Alpine LTP content check supports selecting one architecture' \
    bash "$repo_root/scripts/tests/alpine-ltp-content.sh" --image-dir "$work/no-ltp-images" \
        --arch x86_64
grep -Fq 'rootfs-x86_64-alpine.img' "$work/stderr" || fail 'content check did not select x86_64'
! grep -Eq 'rootfs-(aarch64|riscv64|loongarch64)-alpine.img' "$work/stderr" ||
    fail 'content check inspected an unselected architecture'

fixtures="$work/offline-fixtures"
fixture_sources="$work/fixture-sources"
mkdir -p "$fixtures" "$fixture_sources/rt-tests-2.10" \
    "$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/src" \
    "$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/scripts" \
    "$fixture_sources/iozone3_511/src/current" \
    "$fixture_sources/ltp-full-20260529/runtest"

cat >"$fixture_sources/tiny.c" <<'EOF'
int main(void) { return 0; }
EOF
cp "$fixture_sources/tiny.c" "$fixture_sources/rt-tests-2.10/cyclictest.c"
cat >"$fixture_sources/rt-tests-2.10/Makefile" <<'EOF'
cyclictest:
	$(CC) $(CFLAGS) cyclictest.c $(LDFLAGS) -o cyclictest
EOF

cp "$fixture_sources/tiny.c" \
    "$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/src/tiny.c"
cat >"$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/src/Makefile" <<'EOF'
all:
	mkdir -p ../bin/$(OS)
	$(CC) $(CFLAGS) -c tiny.c -o ../bin/$(OS)/tiny.o
	$(CC) $(CFLAGS) tiny.c $(LDFLAGS) -o ../bin/$(OS)/bw_mem
	$(CC) $(CFLAGS) tiny.c $(LDFLAGS) -o ../bin/$(OS)/lat_syscall
	cp ../scripts/lmbench ../bin/$(OS)/lmbench
	chmod +x ../bin/$(OS)/lmbench
EOF
for script in lmbench config-run results config os gnu-os info info-template version; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/scripts/$script"
    chmod +x "$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/scripts/$script"
done
printf '%s\n' '#!/bin/sh' 'printf "%s\n" Linux' >"$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/scripts/os"
chmod +x "$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/scripts/os"
cat >>"$fixture_sources/lmbench-5a386c1c32a84898151dade7754031813e33994e/scripts/lmbench" <<'EOF'
SERVERS="lat_udp lat_tcp lat_rpc lat_connect bw_tcp"
if [ X$BENCHMARK_RPC = XYES ]; then
    lat_rpc localhost
fi
lat_rpc -S localhost
if [ ! -d ../../src/webpage-lm ]; then
    (cd ../../src && tar xf webpage-lm.tar)
fi
DOCROOT=../../src/webpage-lm lmhttp 8008 &
if [ X$BENCHMARK_HTTP = XYES ]; then
    lat_http localhost 8008 < ../../src/webpage-lm/URLS
fi
lat_http -S localhost 8008
EOF

cp "$fixture_sources/tiny.c" "$fixture_sources/iozone3_511/src/current/iozone.c"
cat >"$fixture_sources/iozone3_511/src/current/Makefile" <<'EOF'
linux:
	$(CC) $(CFLAGS) iozone.c $(LDFLAGS) -o iozone
EOF

cp "$fixture_sources/tiny.c" "$fixture_sources/ltp-full-20260529/timer_create01.c"
cp "$fixture_sources/tiny.c" "$fixture_sources/ltp-full-20260529/timer_create02.c"
cp "$fixture_sources/tiny.c" "$fixture_sources/ltp-full-20260529/timer_create03.c"
cp "$fixture_sources/tiny.c" "$fixture_sources/ltp-full-20260529/hackbench.c"
cp "$fixture_sources/tiny.c" "$fixture_sources/ltp-full-20260529/custom_skip.c"
printf '%s\n' 20260529 >"$fixture_sources/ltp-full-20260529/VERSION"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture_sources/ltp-full-20260529/configure"
chmod +x "$fixture_sources/ltp-full-20260529/configure"
cat >"$fixture_sources/ltp-full-20260529/runtest/syscalls" <<'EOF'
fmtmsg01 fmtmsg01
timer_create01 timer_create01
timer_create02 timer_create02
timer_create03 timer_create03
custom_skip custom_skip
EOF
printf '%s\n' 'sched_rr_get_interval01 sched_rr_get_interval01' 'hackbench01 hackbench 50 process 1000' \
    >"$fixture_sources/ltp-full-20260529/runtest/sched"
cat >"$fixture_sources/ltp-full-20260529/Makefile" <<'EOF'
all:
	$(CC) $(CFLAGS) timer_create01.c $(LDFLAGS) -o timer_create01
	$(CC) $(CFLAGS) timer_create02.c $(LDFLAGS) -o timer_create02
	$(CC) $(CFLAGS) timer_create03.c $(LDFLAGS) -o timer_create03
	$(CC) $(CFLAGS) hackbench.c $(LDFLAGS) -o hackbench
	$(CC) $(CFLAGS) custom_skip.c $(LDFLAGS) -o custom_skip

install: all
	mkdir -p $(DESTDIR)$(PREFIX)/testcases/bin $(DESTDIR)$(PREFIX)/testcases/bin/fmtmsg
	install -m 0755 timer_create01 timer_create02 timer_create03 hackbench custom_skip $(DESTDIR)$(PREFIX)/testcases/bin/
	touch $(DESTDIR)$(PREFIX)/testcases/bin/fmtmsg/fmtmsg01
	touch $(DESTDIR)$(PREFIX)/testcases/bin/fmtmsg02
EOF

tar -cJf "$fixtures/rt-tests-2.10.tar.xz" -C "$fixture_sources" rt-tests-2.10
tar -czf "$fixtures/lmbench-5a386c1c32a84898151dade7754031813e33994e.tar.gz" \
    -C "$fixture_sources" lmbench-5a386c1c32a84898151dade7754031813e33994e
tar -czf "$fixtures/iozone3_511.tgz" -C "$fixture_sources" iozone3_511
tar -cJf "$fixtures/ltp-full-20260529.tar.xz" -C "$fixture_sources" ltp-full-20260529
for fixture in "$fixtures"/*; do
    sha256sum "$fixture" | awk '{print $1}' >"$fixture.sha256"
done

ltp_overlay="$work/ltp-overlay"
run_ok 'ltp plugin builds and installs a checked offline fixture' \
    env ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" ROOTFS_TEST_BUILD_ROOT="$work/ltp-build" \
        bash "$build_script" build --arch x86_64 --rootfs alpine --scope outer \
        --tests ltp --output "$ltp_overlay"
assert_eq 20260529 "$(tr -d '\r\n' <"$ltp_overlay/opt/ltp/Version")" 'ltp Version is retained'
assert_exists "$ltp_overlay/opt/ltp/runtest/syscalls" 'ltp syscall runtest is retained'
assert_exists "$ltp_overlay/opt/ltp/runtest/sched" 'ltp scheduler runtest is retained'
assert_exists "$ltp_overlay/opt/ltp/testcases/bin/timer_create02" 'timer_create02 is retained'
[[ -x $ltp_overlay/opt/ltp/testcases/bin/timer_create02 ]] || fail 'timer_create02 is not executable'
assert_exists "$ltp_overlay/opt/ltp/testcases/bin/hackbench" 'scheduler representative is retained'
[[ -x $ltp_overlay/opt/ltp/testcases/bin/hackbench ]] || fail 'hackbench is not executable'
awk '$1 ~ /^hackbench[0-9_]*$/ && $2 == "hackbench" { found=1 } END { exit !found }' \
    "$ltp_overlay/opt/ltp/runtest/sched" || fail 'hackbench is not referenced by scheduler runtest'
for excluded in timer_create01 timer_create03; do
    [[ ! -e $ltp_overlay/opt/ltp/testcases/bin/$excluded ]] || fail "$excluded was installed"
    ! awk -v testcase="$excluded" '$1 == testcase { found = 1 } END { exit !found }' \
        "$ltp_overlay/opt/ltp/runtest/syscalls" || fail "$excluded runtest entry was retained"
done
[[ ! -e $ltp_overlay/opt/ltp/testcases/bin/fmtmsg ]] || fail 'fmtmsg output directory was installed'
[[ ! -e $ltp_overlay/opt/ltp/testcases/bin/fmtmsg02 ]] || fail 'fmtmsg testcase was installed'
! awk '$1 ~ /^fmtmsg([0-9_]|$)/ { found = 1 } END { exit !found }' \
    "$ltp_overlay/opt/ltp/runtest/syscalls" || fail 'fmtmsg runtest entry was retained'
run_ok 'ltp fixture executable has the requested architecture' \
    rootfs_test_validate_elf x86_64 "$ltp_overlay/opt/ltp/testcases/bin/timer_create02"
run_ok 'ltp scheduler fixture has the requested architecture' \
    rootfs_test_validate_elf x86_64 "$ltp_overlay/opt/ltp/testcases/bin/hackbench"

mkdir "$work/ltp-default-checksum-output"
run_fail 'LTP URL override requires an accompanying checksum' \
    env ALPINE_LTP_URL="file://$fixtures/ltp-full-20260529.tar.xz" \
        ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" \
        ROOTFS_TEST_BUILD_ROOT="$work/ltp-default-checksum-build" \
        "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
        --output "$work/ltp-default-checksum-output"
grep -Fq 'source URL and checksum overrides must be provided together' "$work/stderr" ||
    fail 'LTP URL-only override did not report the paired-override requirement'
mkdir "$work/ltp-sha-only-output"
run_fail 'LTP checksum override requires an accompanying URL' \
    env ALPINE_LTP_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" \
        ROOTFS_TEST_BUILD_ROOT="$work/ltp-sha-only-build" \
        "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
        --output "$work/ltp-sha-only-output"
grep -Fq 'source URL and checksum overrides must be provided together' "$work/stderr" ||
    fail 'LTP checksum-only override did not report the paired-override requirement'
fixture_ltp_sum=$(cat "$fixtures/ltp-full-20260529.tar.xz.sha256")
mkdir "$work/ltp-explicit-checksum-output"
run_ok 'alternate LTP URL accepts an accompanying explicit checksum' \
    env ALPINE_LTP_URL="file://$fixtures/ltp-full-20260529.tar.xz" \
        ALPINE_LTP_SHA256="$fixture_ltp_sum" ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" \
        ROOTFS_TEST_BUILD_ROOT="$work/ltp-override-build" \
        "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
        --output "$work/ltp-explicit-checksum-output"
assert_exists "$work/ltp-override-build/sources/ltp-20260529-$fixture_ltp_sum" \
    'LTP source cache is checksum-addressed'

for invalid_filter in 'fmtmsg;touch_bad' 'timer_create01/touch_bad' "timer'create01" \
                      'timer$(touch_bad)' 'timer`touch_bad`'; do
    invalid_output=$(mktemp -d "$work/ltp-invalid-filter.XXXXXX")
    run_fail "LTP rejects invalid filter token: $invalid_filter" \
        env ALPINE_LTP_FILTER_OUT_DIRS="$invalid_filter" ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" \
            ROOTFS_TEST_BUILD_ROOT="$work/ltp-invalid-filter-build" \
            "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
            --output "$invalid_output"
done

glob_cwd="$work/ltp-filter-glob-cwd"
mkdir "$glob_cwd"
touch "$glob_cwd/benign" "$glob_cwd/a" "$glob_cwd/literal"
for invalid_filter in '*' '?' '[abl]*'; do
    invalid_output=$(mktemp -d "$work/ltp-invalid-glob.XXXXXX")
    tests=$((tests + 1))
    if (cd "$glob_cwd" && env ALPINE_LTP_FILTER_OUT_TESTS="$invalid_filter" \
        ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" ROOTFS_TEST_BUILD_ROOT="$work/ltp-glob-build" \
        "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
        --output "$invalid_output") >"$work/stdout" 2>"$work/stderr"; then
        fail "LTP accepted glob filter token: $invalid_filter"
    fi
    grep -Fq "invalid LTP filter token: $invalid_filter" "$work/stderr" ||
        fail "LTP did not reject original glob token: $invalid_filter"
    pass "LTP rejects original glob filter token: $invalid_filter"
done

custom_overlay="$work/ltp-custom-filter-overlay"
run_ok 'LTP accepts validated non-default testcase exclusions' \
    env ALPINE_LTP_FILTER_OUT_TESTS='timer_create01 custom_skip' \
        ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" ROOTFS_TEST_BUILD_ROOT="$work/ltp-custom-build" \
        bash "$build_script" build --arch x86_64 --rootfs alpine --scope outer \
        --tests ltp --output "$custom_overlay"
[[ ! -e $custom_overlay/opt/ltp/testcases/bin/timer_create01 ]] || fail 'retained default exclusion was installed'
[[ ! -e $custom_overlay/opt/ltp/testcases/bin/custom_skip ]] || fail 'selected custom exclusion was installed'
assert_exists "$custom_overlay/opt/ltp/testcases/bin/timer_create03" 'unselected default exclusion remains available'
! awk '$1 == "timer_create01" || $1 == "custom_skip" { found=1 } END { exit !found }' \
    "$custom_overlay/opt/ltp/runtest/syscalls" || fail 'custom exclusions remain in runtest'
awk '$1 == "timer_create03" { found=1 } END { exit !found }' \
    "$custom_overlay/opt/ltp/runtest/syscalls" || fail 'unselected default testcase was removed from runtest'

fake_real_bin="$work/ltp-fake-real-bin"
mkdir "$fake_real_bin"
cat >"$fake_real_bin/alpine-builder" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' fake-ltp-builder
EOF
cat >"$fake_real_bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_LTP_ARGS_LOG"
printf '%s\0%s\0%s\0%s\0' "$ALPINE_LTP_CFLAGS" "$ALPINE_LTP_LDFLAGS" \
    "$ALPINE_LTP_FILTER_OUT_DIRS" "$ALPINE_LTP_FILTER_OUT_TESTS" >"$FAKE_LTP_ENV_LOG"
printf '%s\n' "${@: -1}" >"$FAKE_LTP_PROGRAM_LOG"
exit 93
EOF
chmod +x "$fake_real_bin/alpine-builder" "$fake_real_bin/docker"
host_marker="$work/ltp-host-injection"
container_marker="$work/ltp-container-injection"
hostile_cflags="  -O2 -DVALUE='quoted value'; touch $host_marker; \$(touch $host_marker); \`touch $host_marker\`  "
hostile_ldflags=" -Wl,--gc-sections; touch $container_marker "
mkdir "$work/ltp-hostile-output"
run_fail 'LTP passes hostile-looking flags as data at the Docker boundary' \
    env PATH="$fake_real_bin:$PATH" ROOTFS_TEST_ALPINE_BUILDER="$fake_real_bin/alpine-builder" \
        FAKE_LTP_ARGS_LOG="$work/ltp-docker-args" FAKE_LTP_ENV_LOG="$work/ltp-env-log" \
        FAKE_LTP_PROGRAM_LOG="$work/ltp-program-log" \
        ALPINE_LTP_URL="file://$fixtures/ltp-full-20260529.tar.xz" \
        ALPINE_LTP_SHA256="$fixture_ltp_sum" ALPINE_LTP_CFLAGS="$hostile_cflags" \
        ALPINE_LTP_LDFLAGS="$hostile_ldflags" ALPINE_LTP_FILTER_OUT_DIRS='fmtmsg other_fmtmsg' \
        ALPINE_LTP_FILTER_OUT_TESTS='timer_create01 timer_create03' \
        ROOTFS_TEST_BUILD_ROOT="$work/ltp-hostile-build" \
        "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
        --output "$work/ltp-hostile-output"
[[ ! -e $host_marker && ! -e $container_marker ]] || fail 'hostile-looking LTP flags caused a command side effect'
mapfile -d '' -t captured_ltp_env <"$work/ltp-env-log"
assert_eq "$hostile_cflags" "${captured_ltp_env[0]}" 'LTP CFLAGS survive the Docker boundary literally'
assert_eq "$hostile_ldflags" "${captured_ltp_env[1]}" 'LTP LDFLAGS survive the Docker boundary literally'
assert_eq 'fmtmsg other_fmtmsg' "${captured_ltp_env[2]}" 'LTP directory filters preserve whitespace'
assert_eq 'timer_create01 timer_create03' "${captured_ltp_env[3]}" 'LTP testcase filters preserve whitespace'
! grep -Fq "$host_marker" "$work/ltp-program-log" || fail 'host CFLAGS were interpolated into container program'
! grep -Fq "$container_marker" "$work/ltp-program-log" || fail 'host LDFLAGS were interpolated into container program'
for variable in ALPINE_LTP_CFLAGS ALPINE_LTP_LDFLAGS ALPINE_LTP_FILTER_OUT_DIRS ALPINE_LTP_FILTER_OUT_TESTS; do
    grep -Fxq "$variable" "$work/ltp-docker-args" || fail "$variable was not passed through Docker environment"
done
mkdir "$work/ltp-interrupted-output"
run_fail 'interrupted LTP extraction preserves failure' \
    env PATH="$fault_bin:$PATH" INTERRUPT_TAR=1 ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" \
        ROOTFS_TEST_BUILD_ROOT="$work/ltp-interrupted-build" \
        "$builtin_plugins/ltp.sh" build --arch x86_64 --rootfs alpine --scope outer \
        --output "$work/ltp-interrupted-output"
[[ -z $(find "$work/ltp-interrupted-build/sources" -mindepth 1 -type d -name '.*' -print -quit) ]] ||
    fail 'interrupted LTP extraction leaked a temporary directory'
run_ok 'ltp uses the checksum-verified shared Alpine builder' grep -F 'alpine-builder.sh' "$builtin_plugins/ltp.sh"
run_ok 'standalone Alpine base no longer installs LTP' \
    bash -c '! grep -Eq "alpine_install_ltp_tests|alpine_ltp_prepare_source|alpine_ensure_ltp_docker_image" "$1"' _ \
        "$repo_root/scripts/rootfs/alpine.sh"

plugin_build_root="$work/plugin-build"
plugin_overlay="$work/builtin-overlay"
run_ok 'built-in guest plugins build checked static fixture sources' \
    env ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" ROOTFS_TEST_BUILD_ROOT="$plugin_build_root" \
        bash "$build_script" build --arch x86_64 --rootfs alpine --scope guest \
        --tests cyclictest,lmbench,iozone --output "$plugin_overlay"
for executable in \
    guest-tests/cyclictest/cyclictest \
    guest-tests/lmbench/bin/Linux/bw_mem \
    guest-tests/lmbench/bin/Linux/lat_syscall \
    guest-tests/iozone/iozone; do
    assert_exists "$plugin_overlay/$executable" "$executable was installed"
    [[ -x $plugin_overlay/$executable ]] || fail "$executable is not executable"
done
for script in lmbench config-run results config os gnu-os info info-template version; do
    assert_exists "$plugin_overlay/guest-tests/lmbench/scripts/$script" "lmbench runtime script $script was installed"
    [[ -x $plugin_overlay/guest-tests/lmbench/scripts/$script ]] || fail "lmbench runtime script $script is not executable"
done
assert_exists "$plugin_overlay/guest-tests/lmbench/bin/Linux/lmbench" 'generated lmbench launcher was installed in its upstream runtime directory'
[[ -x $plugin_overlay/guest-tests/lmbench/bin/Linux/lmbench ]] || fail 'generated lmbench launcher is not executable'
if grep -Eq 'lat_rpc|lat_http|lmhttp|webpage-lm' \
    "$plugin_overlay/guest-tests/lmbench/bin/Linux/lmbench" \
    "$plugin_overlay/guest-tests/lmbench/scripts/lmbench"; then
    fail 'lmbench launchers retain disabled RPC or unpackaged HTTP orchestration'
fi
[[ ! -e $plugin_overlay/guest-tests/lmbench/bin/Linux/tiny.o ]] || fail 'lmbench installed a build object as a runtime executable'
run_ok 'lmbench packaged scripts resolve the preserved bin/Linux runtime layout' \
    bash -c 'cd "$1/guest-tests/lmbench/scripts"; test "$(./os)" = Linux; ../bin/"$(./os)"/bw_mem' \
        _ "$plugin_overlay"
[[ -z $(find "$plugin_overlay" -name run-all.sh -print -quit) ]] || fail 'built-in plugins installed run-all.sh'
for executable in $(find "$plugin_overlay/guest-tests" -type f -perm /111 ! -path '*/scripts/*' ! -name lmbench); do
    rootfs_test_validate_elf x86_64 "$executable" || fail "installed fixture ELF is invalid: $executable"
    ! readelf -l -- "$executable" | grep -q INTERP || fail "installed fixture ELF has an interpreter: $executable"
    ! readelf -d -- "$executable" | grep -q '(NEEDED)' || fail "installed fixture ELF has a needed library: $executable"
done

# Valid source overrides for the same nominal version coexist by checksum.
override_fixture_a="$work/override-fixture-a"
override_fixture_b="$work/override-fixture-b"
mkdir "$override_fixture_a" "$override_fixture_b"
override_a="$override_fixture_a/rt-tests-2.10.tar.xz"
override_b="$override_fixture_b/rt-tests-2.10.tar.xz"
tar -cJf "$override_a" -C "$fixture_sources" rt-tests-2.10
printf variant-b >"$fixture_sources/rt-tests-2.10/variant"
tar -cJf "$override_b" -C "$fixture_sources" rt-tests-2.10
sum_override_a=$(sha256sum "$override_a" | awk '{print $1}')
sum_override_b=$(sha256sum "$override_b" | awk '{print $1}')
printf '%s\n' "$sum_override_a" >"$override_a.sha256"
printf '%s\n' "$sum_override_b" >"$override_b.sha256"
override_build="$work/override-build"
mkdir "$work/override-output-a" "$work/override-output-b"
run_ok 'first valid same-version source override builds' env ROOTFS_TEST_BUILD_ROOT="$override_build" \
    ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$override_fixture_a" \
    "$builtin_plugins/cyclictest.sh" build --arch x86_64 --rootfs alpine --scope guest --output "$work/override-output-a"
run_ok 'second valid same-version source override coexists' env ROOTFS_TEST_BUILD_ROOT="$override_build" \
    ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$override_fixture_b" \
    "$builtin_plugins/cyclictest.sh" build --arch x86_64 --rootfs alpine --scope guest --output "$work/override-output-b"
assert_exists "$override_build/sources/cyclictest-2.10-$sum_override_a" 'first checksum-keyed source directory remains'
assert_exists "$override_build/sources/cyclictest-2.10-$sum_override_b" 'second checksum-keyed source directory exists'

# Failed or interrupted extraction removes all owned temporary directories.
malformed_fixtures="$work/malformed-fixtures"
mkdir "$malformed_fixtures"
printf 'not a tar archive' >"$malformed_fixtures/rt-tests-2.10.tar.xz"
sha256sum "$malformed_fixtures/rt-tests-2.10.tar.xz" | awk '{print $1}' >"$malformed_fixtures/rt-tests-2.10.tar.xz.sha256"
malformed_build="$work/malformed-build"
mkdir "$work/malformed-output"
run_fail 'malformed plugin archive fails extraction' env ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$malformed_fixtures" \
    ROOTFS_TEST_BUILD_ROOT="$malformed_build" "$builtin_plugins/cyclictest.sh" build \
    --arch x86_64 --rootfs alpine --scope guest --output "$work/malformed-output"
[[ -z $(find "$malformed_build/sources" -mindepth 1 -type d -name '.*' -print -quit) ]] || fail 'malformed extraction leaked a temporary directory'

interrupted_build="$work/interrupted-extract-build"
mkdir "$work/interrupted-extract-output"
run_fail 'interrupted plugin extraction preserves failure' env PATH="$fault_bin:$PATH" INTERRUPT_TAR=1 \
    ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" ROOTFS_TEST_BUILD_ROOT="$interrupted_build" \
    "$builtin_plugins/cyclictest.sh" build --arch x86_64 --rootfs alpine --scope guest \
    --output "$work/interrupted-extract-output"
[[ -z $(find "$interrupted_build/sources" -mindepth 1 -type d -name '.*' -print -quit) ]] || fail 'interrupted extraction leaked a temporary directory'

# Builder metadata is pinned and includes inspectable LoongArch provenance.
builder_script="$repo_root/scripts/rootfs-tests/alpine-builder.sh"
run_ok 'LoongArch builder description is checksum-pinned and package-set-addressed' \
    bash "$builder_script" describe --arch loongarch64
builder_description=$(cat "$work/stdout")
[[ $builder_description == *$'version=3.23.5\n'* ]] || fail 'LoongArch builder version is not pinned'
[[ $builder_description == *$'archive=alpine-minirootfs-3.23.5-loongarch64.tar.gz\n'* ]] || fail 'LoongArch builder archive is not pinned'
[[ $builder_description == *$'sha256=92185135af8b8694f9732c4cdc0dae7f26f72059fd79e9bef6d5dbafd05898ea\n'* ]] || fail 'LoongArch builder checksum is not pinned'
[[ $builder_description == *$'platform=linux/loong64\n'* ]] || fail 'LoongArch builder platform is wrong'
[[ $builder_description == *'package_set=build-base-0.5-r3_linux-headers-6.16.12-r0_numactl-dev-2.0.18-r0_python3-3.12.14-r0'* ]] || fail 'builder package set is not version-addressed'
[[ $builder_description == *'archive_cache=alpine-minirootfs-3.23.5-loongarch64-92185135af8b8694f9732c4cdc0dae7f26f72059fd79e9bef6d5dbafd05898ea.tar.gz'* ]] || fail 'builder archive cache is not checksum-addressed'
for plugin in cyclictest lmbench iozone; do
    run_ok "$plugin uses the checksum-verified shared builder" grep -F 'alpine-builder.sh' "$builtin_plugins/$plugin.sh"
    ! grep -Fq 'alpine:3.23' "$builtin_plugins/$plugin.sh" || fail "$plugin still uses a mutable Alpine image reference"
done

run_fail 'built-in guest plugin rejects an unsupported scope through the framework' \
    env ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$fixtures" ROOTFS_TEST_BUILD_ROOT="$plugin_build_root" \
        bash "$build_script" build --arch x86_64 --rootfs alpine --scope outer \
        --tests cyclictest --output "$work/unsupported-builtin-scope"
run_fail 'built-in guest plugin rejects unknown build arguments' \
    "$builtin_plugins/cyclictest.sh" build --arch x86_64 --rootfs alpine --scope guest \
        --output "$work/bad-plugin-args" --unexpected

bad_fixtures="$work/bad-offline-fixtures"
cp -a "$fixtures" "$bad_fixtures"
printf corrupt >>"$bad_fixtures/rt-tests-2.10.tar.xz"
run_fail 'built-in plugin rejects a fixture that fails its sidecar checksum' \
    env ROOTFS_TEST_OFFLINE_FIXTURE_DIR="$bad_fixtures" \
        ROOTFS_TEST_BUILD_ROOT="$plugin_build_root" \
        bash "$build_script" build --arch x86_64 --rootfs alpine --scope guest \
        --tests cyclictest --output "$work/bad-fixture-overlay"

echo "1..$tests"
