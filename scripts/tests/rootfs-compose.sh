#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compose_lib="$repo_root/scripts/lib/rootfs-compose.sh"
work=$(mktemp -d /tmp/rootfs-compose-test.XXXXXX)
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
real_debugfs=$(command -v debugfs)
real_mv=$(command -v mv)
real_find=$(command -v find)
real_mktemp=$(command -v mktemp)
real_flock=$(command -v flock)
fault_bin="$work/fault-bin"
mkdir "$fault_bin"
cat >"$fault_bin/debugfs" <<EOF
#!/usr/bin/env bash
if [[ \${FAIL_DEBUGFS_WRITES:-} == 1 && \${1:-} == -w ]]; then
    exit 70
fi
if [[ \${FAIL_DEBUGFS_WRITES:-} == zero && \${1:-} == -w ]]; then
    exit 0
fi
exec "$real_debugfs" "\$@"
EOF
cat >"$fault_bin/mv" <<EOF
#!/usr/bin/env bash
destination=\${@: -1}
if [[ -n \${FAIL_MV_DESTINATION:-} && \$destination == "\$FAIL_MV_DESTINATION" ]]; then
    exit 71
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$fault_bin/debugfs" "$fault_bin/mv"
cat >"$fault_bin/find" <<EOF
#!/usr/bin/env bash
[[ \${FAIL_FIND:-} != 1 ]] || exit 72
exec "$real_find" "\$@"
EOF
chmod +x "$fault_bin/find"
cat >"$fault_bin/mktemp" <<EOF
#!/usr/bin/env bash
if [[ -n \${MKTEMP_COUNT_FILE:-} ]]; then
    count=0
    [[ ! -f \$MKTEMP_COUNT_FILE ]] || read -r count <"\$MKTEMP_COUNT_FILE"
    count=\$((count + 1))
    printf '%s\n' "\$count" >"\$MKTEMP_COUNT_FILE"
    if [[ \${FAIL_MKTEMP_AT:-0} -eq \$count ]]; then
        exit 73
    fi
    if [[ \${SIGNAL_MKTEMP_BEFORE:-0} -eq \$count ]]; then
        kill -TERM "\$PPID"
        exit 143
    fi
fi
exec "$real_mktemp" "\$@"
EOF
chmod +x "$fault_bin/mktemp"
cat >"$fault_bin/flock" <<EOF
#!/usr/bin/env bash
count_file="\${FLOCK_STATE_PREFIX:-/tmp/rootfs-flock}.\$PPID"
count=0
[[ ! -f \$count_file ]] || read -r count <"\$count_file"
count=\$((count + 1))
printf '%s\n' "\$count" >"\$count_file"
"$real_flock" "\$@" || exit \$?
[[ \${SLOW_FIRST_LOCK:-0} != 1 || \$count -ne 1 ]] || sleep 1
EOF
chmod +x "$fault_bin/flock"

# Libraries use these only for diagnostics.
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { :; }
die() { printf 'error: %s\n' "$1" >&2; return "${2:-1}"; }

source "$repo_root/scripts/lib/rootfs.sh"
source "$compose_lib"

tests=0
fail() { printf 'not ok %s - %s\n' "$tests" "$*" >&2; exit 1; }
pass() { printf 'ok %s - %s\n' "$tests" "$*"; }
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
        fail "$message (unexpected success)"
    fi
    pass "$message"
}
assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$1', got '$2')"
}

make_ext4() {
    local image=$1
    truncate -s 32M "$image"
    chmod 0644 "$image"
    mkfs.ext4 -q -F "$image"
}

normalize_tree_seconds() {
    find "$1" -depth -mindepth 1 -type l -exec touch -h -d @1700000000 {} +
    find "$1" -depth -mindepth 1 ! -type l -exec touch -d @1700000000 {} +
}

fs_field() {
    LC_ALL=C dumpe2fs -h "$1" 2>/dev/null | awk -F: -v key="$2" '
        $1 == key { gsub(/^[[:space:]]+/, "", $2); print $2; exit }
    '
}

debugfs_cat() {
    debugfs -R "cat \"$2\"" "$1" 2>/dev/null
}

has_path() {
    local output
    output=$(debugfs -R "stat $2" "$1" 2>&1) || return 1
    [[ "$output" != *'File not found'* ]]
}

test_parse_sizes() {
    assert_eq 0 "$(rootfs_parse_size_bytes 0)" 'zero bytes parse'
    assert_eq 4096 "$(rootfs_parse_size_bytes 4K)" 'K suffix parses'
    assert_eq 2097152 "$(rootfs_parse_size_bytes 2MiB)" 'MiB suffix parses'
    assert_eq 3000000000 "$(rootfs_parse_size_bytes 3GB)" 'GB suffix parses'
    ! rootfs_parse_size_bytes -1
    ! rootfs_parse_size_bytes 1.5G
    ! rootfs_parse_size_bytes 12wat
    ! rootfs_parse_size_bytes 18446744073709551616G
}
run_ok 'size parser accepts CLI units and rejects malformed or overflowing values' test_parse_sizes

free_image="$work/free.img"
make_ext4 "$free_image"
expected_free=$(($(fs_field "$free_image" 'Free blocks') * $(fs_field "$free_image" 'Block size')))
run_ok 'free-byte calculation matches dumpe2fs block accounting' \
    test "$expected_free" -eq "$(rootfs_ext4_free_bytes "$free_image")"
run_ok 'free-inode calculation matches dumpe2fs accounting' \
    test "$(fs_field "$free_image" 'Free inodes')" -eq "$(rootfs_ext4_free_inodes "$free_image")"

sparse_overlay="$work/sparse-overlay"
mkdir "$sparse_overlay"
truncate -s 9M "$sparse_overlay/sparse"
ln -s sparse "$sparse_overlay/link"
apparent=$(rootfs_overlay_apparent_bytes "$sparse_overlay")
run_ok 'overlay accounting uses sparse file logical length' test "$apparent" -ge $((9 * 1024 * 1024))

capacity_image="$work/capacity.img"
make_ext4 "$capacity_image"
setfattr -n user.rootfs-image-test -v capacity "$capacity_image"
touch -d @1700000001 "$capacity_image"
before_size=$(stat -c %s "$capacity_image")
run_ok 'capacity growth succeeds' rootfs_ensure_ext4_capacity "$capacity_image" 24M 8M
assert_eq 644 "$(stat -c %a "$capacity_image")" 'capacity growth changed image mode'
assert_eq 1700000001 "$(stat -c %Y "$capacity_image")" 'capacity growth changed image timestamp'
assert_eq capacity "$(getfattr -n user.rootfs-image-test --only-values "$capacity_image" 2>/dev/null)" 'capacity growth lost image xattr'
after_size=$(stat -c %s "$capacity_image")
run_ok 'capacity growth is rounded to 4MiB' test $(((after_size - before_size) % (4 * 1024 * 1024))) -eq 0
payload="$work/capacity-payload"
mkdir "$payload"
dd if=/dev/zero of="$payload/data" bs=1M count=24 status=none
normalize_tree_seconds "$payload"
run_ok 'payload injection succeeds after pre-growth' _rootfs_inject_tree_via_debugfs "$capacity_image" "$payload"
run_ok 'post-injection reserve is real, not estimated' test "$(rootfs_ext4_free_bytes "$capacity_image")" -ge $((8 * 1024 * 1024))

test_oversized_pending_inode_counts() {
    local before
    before=$(sha256sum "$capacity_image" | awk '{print $1}')
    ! rootfs_ensure_ext4_capacity "$capacity_image" 0 0 9223372036854775808 || return 1
    [[ "$before" == "$(sha256sum "$capacity_image" | awk '{print $1}')" ]] || return 1
    ! rootfs_ensure_ext4_capacity "$capacity_image" 0 0 184467440737095516160000 || return 1
    [[ "$before" == "$(sha256sum "$capacity_image" | awk '{print $1}')" ]]
}
run_ok 'capacity rejects oversized pending-inode counts without changing image' \
    test_oversized_pending_inode_counts

inode_image="$work/inodes.img"
truncate -s 32M "$inode_image"
chmod 0644 "$inode_image"
mkfs.ext4 -q -F -N 64 "$inode_image"
inode_payload="$work/inode-payload"
mkdir "$inode_payload"
for inode_index in $(seq 1 80); do : >"$inode_payload/file-$inode_index"; done
normalize_tree_seconds "$inode_payload"
required_inodes=$(_rootfs_overlay_required_inodes "$inode_payload")
run_ok 'capacity growth accounts for pending unique inodes' \
    rootfs_ensure_ext4_capacity "$inode_image" 1M 1M "$required_inodes"
run_ok 'inode-aware growth provides enough inodes before injection' \
    test "$(rootfs_ext4_free_inodes "$inode_image")" -ge "$required_inodes"
run_ok 'many empty files inject after inode-aware growth' \
    _rootfs_inject_tree_via_debugfs "$inode_image" "$inode_payload"

compact_image="$work/compact.img"
make_ext4 "$compact_image"
compact_payload="$work/compact-payload"
mkdir "$compact_payload"
dd if=/dev/zero of="$compact_payload/data" bs=1M count=5 status=none
normalize_tree_seconds "$compact_payload"
_rootfs_inject_tree_via_debugfs "$compact_image" "$compact_payload"
setfattr -n user.rootfs-image-test -v compact "$compact_image"
touch -d @1700000002 "$compact_image"
run_ok 'compaction checks, minimizes, truncates, and restores reserve' rootfs_compact_ext4 "$compact_image" 6M
assert_eq 644 "$(stat -c %a "$compact_image")" 'compaction changed image mode'
assert_eq 1700000002 "$(stat -c %Y "$compact_image")" 'compaction changed image timestamp'
assert_eq compact "$(getfattr -n user.rootfs-image-test --only-values "$compact_image" 2>/dev/null)" 'compaction lost image xattr'
compact_blocks=$(fs_field "$compact_image" 'Block count')
compact_block_size=$(fs_field "$compact_image" 'Block size')
run_ok 'compacted backing file exactly matches filesystem size' \
    test "$(stat -c %s "$compact_image")" -eq $((compact_blocks * compact_block_size))
run_ok 'compacted filesystem has requested reserve' test "$(rootfs_ext4_free_bytes "$compact_image")" -ge $((6 * 1024 * 1024))
run_ok 'compacted filesystem is clean' e2fsck -fn "$compact_image"

bad_image="$work/not-ext.img"
printf 'keep-me' >"$bad_image"
bad_hash=$(sha256sum "$bad_image" | awk '{print $1}')
run_fail 'capacity rejects a non-ext image' rootfs_ensure_ext4_capacity "$bad_image" 1M 1M
assert_eq "$bad_hash" "$(sha256sum "$bad_image" | awk '{print $1}')" 'non-ext image was modified'
run_fail 'compaction rejects malformed reserve' rootfs_compact_ext4 "$bad_image" nope
assert_eq "$bad_hash" "$(sha256sum "$bad_image" | awk '{print $1}')" 'malformed input modified image'
dirty_image="$work/dirty.img"
make_ext4 "$dirty_image"
debugfs -w -R 'set_super_value state 2' "$dirty_image" >/dev/null 2>&1
dirty_hash=$(sha256sum "$dirty_image" | awk '{print $1}')
run_fail 'capacity rejects a dirty image without changing it' rootfs_ensure_ext4_capacity "$dirty_image" 1M 1M
assert_eq "$dirty_hash" "$(sha256sum "$dirty_image" | awk '{print $1}')" 'dirty image was modified'

base="$work/base.img"
make_ext4 "$base"
base_seed="$work/base-seed"
mkdir -p "$base_seed/etc"
printf base >"$base_seed/etc/base-marker"
normalize_tree_seconds "$base_seed"
_rootfs_inject_tree_via_debugfs "$base" "$base_seed"
setfattr -n user.rootfs-image-test -v base "$base"
touch -d @1700000003 "$base"
base_hash=$(sha256sum "$base" | awk '{print $1}')
outer_overlay="$work/outer-overlay"
guest_overlay="$work/guest-overlay"
outer_guest="$work/outer-guest"
mkdir -p "$outer_overlay/outer-only" "$guest_overlay/guest-tests/fake" "$outer_guest/builder"
printf outer >"$outer_overlay/outer-only/fixture"
printf nested >"$guest_overlay/guest-tests/fake/payload"
printf builder >"$outer_guest/builder/content"
normalize_tree_seconds "$outer_overlay"
normalize_tree_seconds "$guest_overlay"
normalize_tree_seconds "$outer_guest"
output="$work/output.img"
run_ok 'compose publishes outer and nested guest images' \
    rootfs_compose_test_images "$base" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 2M 3M "$output"
assert_eq 644 "$(stat -c %a "$output")" 'composition changed image mode'
assert_eq 1700000003 "$(stat -c %Y "$output")" 'composition changed base image timestamp'
assert_eq base "$(getfattr -n user.rootfs-image-test --only-values "$output" 2>/dev/null)" 'composition lost base image xattr'
assert_eq "$base_hash" "$(sha256sum "$base" | awk '{print $1}')" 'compose changed base'
run_ok 'outer contains outer-only payload' has_path "$output" /outer-only/fixture
run_ok 'outer contains builder guest content' has_path "$output" /guest/builder/content
run_ok 'outer contains nested guest image' has_path "$output" /guest/rootfs-x86_64-busybox.img
nested="$work/nested.img"
debugfs -R "dump /guest/rootfs-x86_64-busybox.img $nested" "$output" >/dev/null 2>&1
run_ok 'nested guest contains guest-test payload' has_path "$nested" /guest-tests/fake/payload
run_fail 'nested guest excludes outer-only payload' has_path "$nested" /outer-only/fixture
run_fail 'nested guest excludes builder guest content' has_path "$nested" /guest/builder/content
run_fail 'nested guest is not recursive' has_path "$nested" /guest/rootfs-x86_64-busybox.img
run_ok 'nested and outer are distinct images' test "$(sha256sum "$nested" | awk '{print $1}')" != "$(sha256sum "$output" | awk '{print $1}')"

collision_guest="$work/collision-guest"
mkdir "$collision_guest"
printf collision >"$collision_guest/rootfs-x86_64-busybox.img"
printf old >"$work/preserved-output"
preserved_hash=$(sha256sum "$work/preserved-output" | awk '{print $1}')
run_fail 'compose rejects collision before output modification' \
    rootfs_compose_test_images "$base" "$outer_overlay" "$guest_overlay" "$collision_guest" \
        x86_64 busybox 1M 1M "$work/preserved-output"
assert_eq "$preserved_hash" "$(sha256sum "$work/preserved-output" | awk '{print $1}')" 'collision changed output'

test_protected_outer_overlay_collisions() {
    local kind collision_overlay="$work/protected-compose-overlay" output_hash base_before
    for kind in file directory symlink; do
        rm -rf "$collision_overlay"
        mkdir -p "$collision_overlay/guest"
        case $kind in
            file) printf collision >"$collision_overlay/guest/rootfs-x86_64-busybox.img" ;;
            directory) mkdir "$collision_overlay/guest/rootfs-x86_64-busybox.img" ;;
            symlink) ln -s elsewhere "$collision_overlay/guest/rootfs-x86_64-busybox.img" ;;
        esac
        printf preserved >"$work/protected-compose-output"
        output_hash=$(sha256sum "$work/protected-compose-output" | awk '{print $1}')
        base_before=$(sha256sum "$base" | awk '{print $1}')
        ! rootfs_compose_test_images "$base" "$collision_overlay" "$guest_overlay" "$outer_guest" \
            x86_64 busybox 1M 1M "$work/protected-compose-output"
        assert_eq "$output_hash" "$(sha256sum "$work/protected-compose-output" | awk '{print $1}')" \
            "protected $kind collision changed output"
        assert_eq "$base_before" "$(sha256sum "$base" | awk '{print $1}')" \
            "protected $kind collision changed base"
    done

    rm -rf "$collision_overlay"
    mkdir "$collision_overlay"
    ln -s elsewhere "$collision_overlay/guest"
    printf preserved >"$work/protected-compose-output"
    output_hash=$(sha256sum "$work/protected-compose-output" | awk '{print $1}')
    base_before=$(sha256sum "$base" | awk '{print $1}')
    ! rootfs_compose_test_images "$base" "$collision_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$work/protected-compose-output"
    assert_eq "$output_hash" "$(sha256sum "$work/protected-compose-output" | awk '{print $1}')" \
        'protected ancestor conflict changed output'
    assert_eq "$base_before" "$(sha256sum "$base" | awk '{print $1}')" \
        'protected ancestor conflict changed base'
}
run_ok 'compose preflight rejects protected overlay paths and ancestor conflicts' \
    test_protected_outer_overlay_collisions

test_base_output_aliases() {
    local alias_dir="$work/base-output-alias" candidate before hardlink
    mkdir "$alias_dir"

    candidate="$alias_dir/direct.img"
    cp --reflink=auto --sparse=always "$base" "$candidate"
    before=$(sha256sum "$candidate" | awk '{print $1}')
    ! rootfs_compose_test_images "$candidate" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$candidate"
    assert_eq "$before" "$(sha256sum "$candidate" | awk '{print $1}')" 'direct base/output alias changed base'

    candidate="$alias_dir/lexical.img"
    cp --reflink=auto --sparse=always "$base" "$candidate"
    before=$(sha256sum "$candidate" | awk '{print $1}')
    ! rootfs_compose_test_images "$candidate" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$alias_dir/./lexical.img"
    assert_eq "$before" "$(sha256sum "$candidate" | awk '{print $1}')" 'lexical base/output alias changed base'

    candidate="$alias_dir/inode.img"
    hardlink="$alias_dir/inode-output.img"
    cp --reflink=auto --sparse=always "$base" "$candidate"
    ln "$candidate" "$hardlink"
    before=$(sha256sum "$candidate" | awk '{print $1}')
    ! rootfs_compose_test_images "$candidate" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$hardlink"
    assert_eq "$before" "$(sha256sum "$candidate" | awk '{print $1}')" 'hardlink base/output alias changed base'
    [[ "$candidate" -ef "$hardlink" ]] || fail 'hardlink alias was replaced'
}
run_ok 'compose rejects direct, lexical, and same-inode base/output aliases' test_base_output_aliases

merge_collision_overlay="$work/merge-collision-overlay"
mkdir -p "$merge_collision_overlay/guest/builder"
printf overwrite >"$merge_collision_overlay/guest/builder/content"
run_fail 'compose rejects file collisions between outer guest and outer overlay' \
    rootfs_compose_test_images "$base" "$merge_collision_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$work/preserved-output"
assert_eq "$preserved_hash" "$(sha256sum "$work/preserved-output" | awk '{print $1}')" 'merge collision changed output'
run_fail 'compose rejects cpio.gz base/output' \
    rootfs_compose_test_images "$base.cpio.gz" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$work/no-output"
run_fail 'compose rejects cpio.gz output name' \
    rootfs_compose_test_images "$base" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$work/output.cpio.gz"

atomic="$work/atomic.img"
cp --preserve=all --reflink=auto --sparse=always "$base" "$atomic"
existing_stage="$work/existing-stage"
mkdir -p "$existing_stage/guest"
printf original-nested >"$existing_stage/guest/rootfs-x86_64-busybox.img"
normalize_tree_seconds "$existing_stage"
_rootfs_inject_tree_via_debugfs "$atomic" "$existing_stage"
touch -d @1700000003 "$atomic"
guest_source="$work/inject-guest"
overlay_source="$work/inject-overlay"
mkdir -p "$guest_source/more" "$overlay_source/outer-added"
dd if=/dev/zero of="$guest_source/more/large" bs=1M count=18 status=none
printf added >"$overlay_source/outer-added/payload"
normalize_tree_seconds "$guest_source"
normalize_tree_seconds "$overlay_source"
run_ok 'atomic outer injection grows, injects, validates, and publishes' \
    rootfs_inject_outer_payload_atomic "$atomic" "$guest_source" "$overlay_source" \
        rootfs-x86_64-busybox.img 5M
assert_eq 644 "$(stat -c %a "$atomic")" 'atomic injection changed image mode'
assert_eq 1700000003 "$(stat -c %Y "$atomic")" 'atomic injection changed image timestamp'
assert_eq base "$(getfattr -n user.rootfs-image-test --only-values "$atomic" 2>/dev/null)" 'atomic injection lost image xattr'
run_ok 'atomic injection leaves requested reserve' test "$(rootfs_ext4_free_bytes "$atomic")" -ge $((5 * 1024 * 1024))
run_ok 'atomic injection puts guest source under guest' has_path "$atomic" /guest/more/large
run_ok 'atomic injection puts overlay at root' has_path "$atomic" /outer-added/payload
assert_eq original-nested "$(debugfs_cat "$atomic" /guest/rootfs-x86_64-busybox.img)" \
    'atomic injection changed existing nested image bytes'

protected_source="$work/protected-source"
mkdir "$protected_source"
printf bad >"$protected_source/rootfs-x86_64-busybox.img"
atomic_hash=$(sha256sum "$atomic" | awk '{print $1}')
run_fail 'atomic injection rejects protected top-level guest basename' \
    rootfs_inject_outer_payload_atomic "$atomic" "$protected_source" "$overlay_source" \
        rootfs-x86_64-busybox.img 1M
assert_eq "$atomic_hash" "$(sha256sum "$atomic" | awk '{print $1}')" 'protected collision changed image'

special_overlay="$work/special-overlay"
mkdir "$special_overlay"
mkfifo "$special_overlay/fifo"
run_fail 'atomic injection rolls back when payload validation fails' \
    rootfs_inject_outer_payload_atomic "$atomic" "$guest_source" "$special_overlay" \
        rootfs-x86_64-busybox.img 1M
assert_eq "$atomic_hash" "$(sha256sum "$atomic" | awk '{print $1}')" 'failed injection changed image'

protected_overlay="$work/protected-overlay"
mkdir -p "$protected_overlay/guest"
printf overwrite >"$protected_overlay/guest/rootfs-x86_64-busybox.img"
run_fail 'atomic injection rejects an overlay targeting the protected nested image' \
    rootfs_inject_outer_payload_atomic "$atomic" "$guest_source" "$protected_overlay" \
        rootfs-x86_64-busybox.img 1M
assert_eq "$atomic_hash" "$(sha256sum "$atomic" | awk '{print $1}')" 'protected overlay changed image'

test_mutating_injection_rollback() {
    PATH="$fault_bin:$PATH" FAIL_DEBUGFS_WRITES=1 \
        rootfs_inject_outer_payload_atomic "$atomic" "$guest_source" "$overlay_source" \
            rootfs-x86_64-busybox.img 1M
}
run_fail 'atomic injection preserves the original after a mutating-phase failure' test_mutating_injection_rollback
assert_eq "$atomic_hash" "$(sha256sum "$atomic" | awk '{print $1}')" 'mutating failure changed image'

metadata_image="$work/metadata.img"
make_ext4 "$metadata_image"
metadata_source="$work/metadata-source"
mkdir -p "$metadata_source/private dir"
chmod 0700 "$metadata_source/private dir"
printf spaced >"$metadata_source/private dir/file with space"
printf glob >"$metadata_source/[*]-glob"
printf dash >"$metadata_source/-leading"
printf linked >"$metadata_source/hard-a"
ln "$metadata_source/hard-a" "$metadata_source/hard-b"
ln -s 'target with space' "$metadata_source/link with space"
touch -d @1700000000 "$metadata_source/private dir" "$metadata_source/private dir/file with space"
normalize_tree_seconds "$metadata_source"
run_ok 'debugfs injection handles quoted names and preserves supported metadata' \
    _rootfs_inject_tree_via_debugfs "$metadata_image" "$metadata_source"
run_ok 'space-containing file is complete' test "$(debugfs_cat "$metadata_image" '/private dir/file with space')" = spaced
run_ok 'glob name is literal' test "$(debugfs_cat "$metadata_image" '/[*]-glob')" = glob
run_ok 'leading dash name is literal' test "$(debugfs_cat "$metadata_image" '/-leading')" = dash
metadata_stat=$(debugfs -R 'stat "/private dir"' "$metadata_image" 2>/dev/null)
run_ok 'directory mode is preserved' test "$(sed -n 's/.*Mode:[[:space:]]*\([0-7][0-7]*\).*/\1/p' <<<"$metadata_stat")" = 0700
mtime_hex=$(printf '%x' 1700000000)
run_ok 'fixed timestamp is preserved' test "$metadata_stat" != "${metadata_stat/mtime: 0x$mtime_hex/}"
inode_a=$(debugfs -R 'stat "/hard-a"' "$metadata_image" 2>/dev/null | awk '/^Inode:/ {print $2}')
inode_b=$(debugfs -R 'stat "/hard-b"' "$metadata_image" 2>/dev/null | awk '/^Inode:/ {print $2}')
run_ok 'hardlink relationships are preserved' test "$inode_a" = "$inode_b"
link_stat=$(debugfs -R 'stat "/link with space"' "$metadata_image" 2>/dev/null)
run_ok 'symlink target with spaces is preserved' test "$link_stat" != "${link_stat/Fast link dest: \"target with space\"/}"

bad_payload_image="$work/bad-payload.img"
make_ext4 "$bad_payload_image"
bad_payload_hash=$(sha256sum "$bad_payload_image" | awk '{print $1}')
newline_source="$work/newline-source"
mkdir "$newline_source"
printf bad >"$newline_source/"$'line\nbreak'
run_fail 'debugfs injection rejects newline paths before modification' \
    _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$newline_source"
assert_eq "$bad_payload_hash" "$(sha256sum "$bad_payload_image" | awk '{print $1}')" 'newline rejection modified image'
unrepresentable_source="$work/unrepresentable-source"
mkdir "$unrepresentable_source"
printf quote >"$unrepresentable_source/quote\"name"
printf slash >"$unrepresentable_source/back\\slash"
run_fail 'debugfs injection rejects names its command parser cannot represent' \
    _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$unrepresentable_source"
assert_eq "$bad_payload_hash" "$(sha256sum "$bad_payload_image" | awk '{print $1}')" 'unrepresentable-name rejection modified image'
fractional_source="$work/fractional-source"
mkdir "$fractional_source"
printf fractional >"$fractional_source/file"
touch -d '2024-01-01 00:00:00.123456789 UTC' "$fractional_source/file"
run_fail 'debugfs injection rejects fractional timestamps before modification' \
    _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$fractional_source"
assert_eq "$bad_payload_hash" "$(sha256sum "$bad_payload_image" | awk '{print $1}')" 'fractional timestamp rejection modified image'
fifo_source="$work/fifo-source"
mkdir "$fifo_source"
mkfifo "$fifo_source/fifo"
run_fail 'debugfs injection rejects special objects before modification' \
    _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$fifo_source"
assert_eq "$bad_payload_hash" "$(sha256sum "$bad_payload_image" | awk '{print $1}')" 'special-object rejection modified image'
xattr_source="$work/xattr-source"
mkdir "$xattr_source"
printf xattr >"$xattr_source/file"
setfattr -n user.rootfs-test -v value "$xattr_source/file"
run_fail 'debugfs injection rejects xattrs it cannot preserve' \
    _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$xattr_source"
assert_eq "$bad_payload_hash" "$(sha256sum "$bad_payload_image" | awk '{print $1}')" 'xattr rejection modified image'
test_find_failure() {
    PATH="$fault_bin:$PATH" FAIL_FIND=1 \
        _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$metadata_source"
}
run_fail 'debugfs injection propagates inventory find failure' test_find_failure
assert_eq "$bad_payload_hash" "$(sha256sum "$bad_payload_image" | awk '{print $1}')" 'find failure modified image'
semantic_image="$work/semantic.img"
make_ext4 "$semantic_image"
semantic_hash=$(sha256sum "$semantic_image" | awk '{print $1}')
test_semantic_debugfs_failure() {
    PATH="$fault_bin:$PATH" FAIL_DEBUGFS_WRITES=1 \
        _rootfs_inject_tree_via_debugfs "$semantic_image" "$metadata_source"
}
run_fail 'debugfs semantic write failure cannot report incomplete success' test_semantic_debugfs_failure
test_zero_exit_semantic_debugfs_failure() {
    PATH="$fault_bin:$PATH" FAIL_DEBUGFS_WRITES=zero \
        _rootfs_inject_tree_via_debugfs "$semantic_image" "$metadata_source"
}
run_fail 'manifest catches a semantic debugfs no-op that exits zero' test_zero_exit_semantic_debugfs_failure
readonly_image="$work/readonly.img"
make_ext4 "$readonly_image"
readonly_source="$work/readonly-source"
mkdir -p "$readonly_source/private"
printf readonly >"$readonly_source/private/file"
normalize_tree_seconds "$readonly_source"
chmod 0444 "$readonly_source/private/file"
chmod 0555 "$readonly_source/private" "$readonly_source"
readonly_root_ctime=$(stat -c %z "$readonly_source")
readonly_file_ctime=$(stat -c %z "$readonly_source/private/file")
run_ok 'debugfs injection accepts a read-only payload tree' \
    _rootfs_inject_tree_via_debugfs "$readonly_image" "$readonly_source"
assert_eq "$readonly_root_ctime" "$(stat -c %z "$readonly_source")" 'injector changed source root ctime'
assert_eq "$readonly_file_ctime" "$(stat -c %z "$readonly_source/private/file")" 'injector changed source file ctime'
readonly_stat=$(debugfs -R 'stat "/private/file"' "$readonly_image" 2>/dev/null)
run_ok 'read-only file mode comes from captured manifest' \
    test "$(sed -n 's/.*Mode:[[:space:]]*\([0-7][0-7]*\).*/\1/p' <<<"$readonly_stat")" = 0444

rootfs_temp_residue() {
    find "$work" -maxdepth 1 \( -name '.rootfs-payload.*' -o -name '.rootfs-inventory.*' \
        -o -name '.rootfs-verify.*' -o -name '.guest-snapshot.*' -o -name '.overlay-snapshot.*' \
        -o -name '.atomic.img.inject.*' \) -print -quit
}

test_debugfs_mktemp_cleanup() {
    local boundary count_file="$work/mktemp-count" before
    before=$(sha256sum "$bad_payload_image" | awk '{print $1}')
    for boundary in 1 2 3 4; do
        rm -f "$count_file"
        PATH="$fault_bin:$PATH" MKTEMP_COUNT_FILE="$count_file" FAIL_MKTEMP_AT="$boundary" \
            _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$metadata_source" && return 1
        [[ -z $(rootfs_temp_residue) ]] || return 1
        [[ "$before" == "$(sha256sum "$bad_payload_image" | awk '{print $1}')" ]] || return 1
    done
}
run_ok 'debugfs injector cleans every partially allocated temporary set' test_debugfs_mktemp_cleanup

test_debugfs_signal_window_cleanup() {
    local count_file="$work/mktemp-count" before
    before=$(sha256sum "$bad_payload_image" | awk '{print $1}')
    rm -f "$count_file"
    PATH="$fault_bin:$PATH" MKTEMP_COUNT_FILE="$count_file" SIGNAL_MKTEMP_BEFORE=2 \
        _rootfs_inject_tree_via_debugfs "$bad_payload_image" "$metadata_source" && return 1
    [[ -z $(rootfs_temp_residue) ]] || return 1
    [[ "$before" == "$(sha256sum "$bad_payload_image" | awk '{print $1}')" ]]
}
run_ok 'debugfs injector signal window cleans already registered temporaries' test_debugfs_signal_window_cleanup

test_atomic_mktemp_cleanup() {
    local boundary count_file="$work/mktemp-count" before
    before=$(sha256sum "$atomic" | awk '{print $1}')
    for boundary in 1 2 3; do
        rm -f "$count_file"
        PATH="$fault_bin:$PATH" MKTEMP_COUNT_FILE="$count_file" FAIL_MKTEMP_AT="$boundary" \
            rootfs_inject_outer_payload_atomic "$atomic" "$guest_source" "$overlay_source" \
                rootfs-x86_64-busybox.img 1M && return 1
        [[ -z $(rootfs_temp_residue) ]] || return 1
        [[ "$before" == "$(sha256sum "$atomic" | awk '{print $1}')" ]] || return 1
    done
}
run_ok 'atomic outer injector cleans failures at each pre-injection allocation boundary' test_atomic_mktemp_cleanup

test_atomic_signal_window_cleanup() {
    local count_file="$work/mktemp-count" before
    before=$(sha256sum "$atomic" | awk '{print $1}')
    rm -f "$count_file"
    PATH="$fault_bin:$PATH" MKTEMP_COUNT_FILE="$count_file" SIGNAL_MKTEMP_BEFORE=3 \
        rootfs_inject_outer_payload_atomic "$atomic" "$guest_source" "$overlay_source" \
            rootfs-x86_64-busybox.img 1M && return 1
    [[ -z $(rootfs_temp_residue) ]] || return 1
    [[ "$before" == "$(sha256sum "$atomic" | awk '{print $1}')" ]]
}
run_ok 'atomic outer injector signal window cleans registered temporaries' test_atomic_signal_window_cleanup

failed_publish="$work/failed-publish.img"
printf 'publication-sentinel' >"$failed_publish"
failed_publish_hash=$(sha256sum "$failed_publish" | awk '{print $1}')
test_failed_publication() {
    PATH="$fault_bin:$PATH" FAIL_MV_DESTINATION="$failed_publish" \
        rootfs_compose_test_images "$base" "$outer_overlay" "$guest_overlay" "$outer_guest" \
            x86_64 busybox 1M 1M "$failed_publish"
}
run_fail 'failed final publication preserves an old output' test_failed_publication
assert_eq "$failed_publish_hash" "$(sha256sum "$failed_publish" | awk '{print $1}')" \
    'failed publication changed old output'

printf 'old-output' >"$work/replaced.img"
normalize_tree_seconds "$outer_overlay"
normalize_tree_seconds "$guest_overlay"
normalize_tree_seconds "$outer_guest"
run_ok 'successful composition safely replaces an old output' \
    rootfs_compose_test_images "$base" "$outer_overlay" "$guest_overlay" "$outer_guest" \
        x86_64 busybox 1M 1M "$work/replaced.img"
run_ok 'replacement output is an ext4 filesystem' test "$(_rootfs_detect_fs_type "$work/replaced.img")" = ext4

test_concurrent_base_replacement_consistency() {
    local concurrent_base="$work/concurrent-base.img" concurrent_output="$work/concurrent-output.img"
    local writer_guest="$work/concurrent-writer-guest" writer_overlay="$work/concurrent-writer-overlay"
    local compose_pid writer_pid observed=0 nested_copy="$work/concurrent-nested.img" attempt
    cp --preserve=all --reflink=auto --sparse=always "$base" "$concurrent_base"
    normalize_tree_seconds "$outer_overlay"
    normalize_tree_seconds "$guest_overlay"
    normalize_tree_seconds "$outer_guest"
    mkdir -p "$writer_guest" "$writer_overlay/etc"
    printf new-version >"$writer_overlay/etc/base-marker"
    normalize_tree_seconds "$writer_overlay"
    (
        rootfs_compose_test_images "$concurrent_base" "$outer_overlay" "$guest_overlay" "$outer_guest" \
            x86_64 busybox 1M 1M "$concurrent_output"
    ) &
    compose_pid=$!
    for attempt in $(seq 1 500); do
        if find "$work" -maxdepth 1 -name '.concurrent-output.img.base.*' -print -quit | grep -q .; then
            observed=1
            break
        fi
        sleep 0.01
    done
    [[ $observed -eq 1 ]] || { wait "$compose_pid" || true; return 1; }
    (
        rootfs_inject_outer_payload_atomic "$concurrent_base" "$writer_guest" "$writer_overlay" \
            rootfs-x86_64-busybox.img 1M
    ) &
    writer_pid=$!
    wait "$compose_pid" || return 1
    wait "$writer_pid" || return 1
    [[ "$(debugfs_cat "$concurrent_output" /etc/base-marker)" == base ]] || return 1
    debugfs -R "dump /guest/rootfs-x86_64-busybox.img $nested_copy" "$concurrent_output" >/dev/null 2>&1 || return 1
    [[ "$(debugfs_cat "$nested_copy" /etc/base-marker)" == base ]] || return 1
    [[ "$(debugfs_cat "$concurrent_base" /etc/base-marker)" == new-version ]] || return 1
    e2fsck -fn "$concurrent_base" >/dev/null 2>&1
}
run_ok 'locked base snapshot keeps concurrent outer and nested versions consistent' \
    test_concurrent_base_replacement_consistency

test_mixed_locale_lock_order() {
    local locale_b="$work/locale-B.img" locale_a="$work/locale-a.img" p1 p2 deadline
    local empty_one="$work/locale-empty-one" empty_two="$work/locale-empty-two"
    mkdir "$empty_one" "$empty_two"
    cp --preserve=all --reflink=auto --sparse=always "$base" "$locale_b"
    cp --preserve=all --reflink=auto --sparse=always "$base" "$locale_a"
    (LC_ALL=C PATH="$fault_bin:$PATH" SLOW_FIRST_LOCK=1 FLOCK_STATE_PREFIX="$work/flock-C" \
        rootfs_compose_test_images "$locale_b" "$empty_one" "$empty_two" "$empty_one" \
            x86_64 busybox 1M 1M "$locale_a") &
    p1=$!
    (LC_ALL=en_US.utf8 PATH="$fault_bin:$PATH" SLOW_FIRST_LOCK=1 FLOCK_STATE_PREFIX="$work/flock-en" \
        rootfs_compose_test_images "$locale_a" "$empty_one" "$empty_two" "$empty_one" \
            x86_64 busybox 1M 1M "$locale_b") &
    p2=$!
    deadline=$((SECONDS + 25))
    while kill -0 "$p1" 2>/dev/null || kill -0 "$p2" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            kill "$p1" "$p2" 2>/dev/null || true
            wait "$p1" "$p2" 2>/dev/null || true
            return 1
        fi
        sleep 0.05
    done
    wait "$p1" || return 1
    wait "$p2" || return 1
    [[ "$(_rootfs_detect_fs_type "$locale_a")" == ext4 && "$(_rootfs_detect_fs_type "$locale_b")" == ext4 ]]
}
run_ok 'mixed-locale inverse publishers use one bounded lock order' test_mixed_locale_lock_order

printf '1..%s\n' "$tests"
