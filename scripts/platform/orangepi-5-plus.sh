#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    source "${ROOT_DIR}/scripts/lib/platform-graph-entry.sh"
fi
source "${ROOT_DIR}/scripts/lib/build-paths.sh"
build_paths_init "$ROOT_DIR"

# Repository and directory configuration
LINUX_REPO_URL="https://github.com/orangepi-xunlong/orangepi-build.git"
LINUX_REF="a616d6f7cf06fcc2e708191930f5aa9eb2193115"
LINUX_SRC_DIR="${BUILD_DIR}/orangepi"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/orangepi"
PLATFORM_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi"
PLATFORM_ROOTFS_DIR="${ROOT_DIR}/IMAGES/rootfs"
UBOOT_SCRIPT="${SCRIPT_DIR}/../tools/build-u-boot-orangepi5.sh.sh"
ORANGEPI_UBOOT_WORKDIR="${ORANGEPI_UBOOT_WORKDIR:-${BUILD_DIR}/orangepi-u-boot}"
ORANGEPI_ROOTFS_TYPE="${ORANGEPI_ROOTFS_TYPE:-orangepi-jammy}"
ORANGEPI_GUEST_TESTS="${ORANGEPI_GUEST_TESTS:-cyclictest,lmbench,iozone}"
ORANGEPI_GUEST_FREE_SIZE="${ORANGEPI_GUEST_FREE_SIZE:-256M}"
ORANGEPI_OUTER_FREE_SIZE="${ORANGEPI_OUTER_FREE_SIZE:-256M}"
ORANGEPI_BASE_IMAGE="${ORANGEPI_BASE_IMAGE:-${BUILD_DIR}/orangepi-rootfs/orangepi-5-plus-base.img}"
ORANGEPI_GUEST_ROOTFS="${ORANGEPI_GUEST_ROOTFS:-${PLATFORM_ROOTFS_DIR}/rootfs-aarch64-${ORANGEPI_ROOTFS_TYPE}.img}"

orangepi_linux_is_clean() {
    local argument
    for argument in "$@"; do
        [[ $argument != clean ]] || return 0
    done
    return 1
}

orangepi_validate_uboot_workdir() {
    local build_root safe_path safe_root work_root
    build_root=$(realpath -m -- "$BUILD_DIR") || return 1
    safe_path="${BUILD_DIR}/orangepi-u-boot"
    [[ ! -L $safe_path ]] || {
        printf 'Unsafe Orange Pi U-Boot trust root is a symlink: %s\n' "$safe_path" >&2
        return 1
    }
    safe_root=$(realpath -m -- "$safe_path") || return 1
    [[ $safe_root == "$build_root/orangepi-u-boot" ]] || return 1
    work_root=$(realpath -m -- "$ORANGEPI_UBOOT_WORKDIR") || return 1
    [[ $work_root == "$safe_root" || $work_root == "$safe_root/"* ]] || {
        printf 'Unsafe Orange Pi U-Boot work directory: %s (must be %s or its child)\n' \
            "$work_root" "$safe_root" >&2
        return 1
    }
}

orangepi_configure_source_excludes() {
    local repository=$1 git_dir exclude_file pattern
    [[ -d $repository/.git ]] || return 0
    git_dir=$(git -C "$repository" rev-parse --absolute-git-dir) || return 1
    exclude_file="${git_dir}/info/exclude"
    mkdir -p "$(dirname -- "$exclude_file")"
    touch "$exclude_file"
    for pattern in /scripts/wget-log '/scripts/wget-log.[0-9]*' /u-boot-work/; do
        grep -Fqx -- "$pattern" "$exclude_file" || printf '%s\n' "$pattern" >>"$exclude_file"
    done
}

orangepi_assert_safe_source_tree() {
    local repository=$1 status entry code path patch patch_base allowed head commit patch_id
    local -A allowed_paths=()
    local -A allowed_patch_ids=()

    [[ -d $repository/.git ]] || return 0
    if [[ -n ${LINUX_REF:-} ]]; then
        git -C "$repository" cat-file -e "${LINUX_REF}^{tree}" 2>/dev/null || {
            printf 'Orange Pi source cache cannot verify fixed ref %s; refusing destructive checkout\n' \
                "$LINUX_REF" >&2
            return 1
        }
        if [[ -d ${LINUX_PATCH_DIR:-} ]]; then
            for patch in "$LINUX_PATCH_DIR"/*.patch "$LINUX_PATCH_DIR"/*.diff; do
                [[ -f $patch ]] || continue
                patch_id=$(git patch-id --stable <"$patch" | awk 'NR == 1 {print $1}')
                [[ -z $patch_id ]] || allowed_patch_ids[$patch_id]=1
            done
        fi
        head=$(git -C "$repository" rev-parse HEAD) || return 1
        if [[ $head != "$LINUX_REF" ]]; then
            git -C "$repository" merge-base --is-ancestor "$LINUX_REF" "$head" || {
                printf 'Orange Pi source cache HEAD is unrelated to fixed ref %s\n' "$LINUX_REF" >&2
                return 1
            }
            while IFS= read -r commit; do
                patch_id=$(git -C "$repository" show --pretty=format: --binary "$commit" |
                    git patch-id --stable | awk 'NR == 1 {print $1}')
                [[ -n $patch_id && -n ${allowed_patch_ids[$patch_id]-} ]] || {
                    printf 'Orange Pi source cache has a local commit outside fixed patches: %s\n' "$commit" >&2
                    return 1
                }
            done < <(git -C "$repository" rev-list --reverse "${LINUX_REF}..${head}")
        fi
    fi
    status=$(git -C "$repository" status --porcelain=v1 --untracked-files=all) || return 1
    [[ -n $status ]] || return 0

    if [[ -d ${LINUX_PATCH_DIR:-} ]]; then
        for patch in "$LINUX_PATCH_DIR"/*.patch "$LINUX_PATCH_DIR"/*.diff; do
            [[ -f $patch ]] || continue
            if git -C "$repository" apply --reverse --check "$patch" >/dev/null 2>&1; then
                while IFS= read -r path; do
                    [[ -n $path && $path != /dev/null ]] && allowed_paths[$path]=1
                done < <(sed -n 's@^+++ b/@@p; s@^--- a/@@p' "$patch" | LC_ALL=C sort -u)
            fi
            patch_base=$(basename -- "$patch")
            allowed_paths[".patch_stamps/${patch_base}.applied"]=1
        done
    fi

    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        code=${entry:0:2}
        path=${entry:3}
        [[ $code != *R* && $code != *C* ]] || {
            printf 'Orange Pi source cache has an unsafe rename/copy: %s\n' "$entry" >&2
            return 1
        }
        allowed=${allowed_paths[$path]-}
        if [[ -n $allowed && $path == .patch_stamps/*.applied ]]; then
            [[ -f $repository/$path && -z $(<"$repository/$path") ]] || allowed=
        fi
        if [[ -z $allowed && $path == userpatches/lib.config && -f $repository/$path ]]; then
            if [[ $(<"$repository/$path") == $'IMAGE_PARTITION_TABLE=gpt\nBOOTFS_TYPE=fat\nBOOTSIZE=1024' ]]; then
                allowed=1
            fi
        fi
        [[ -n $allowed ]] || {
            printf 'Orange Pi source cache has uncommitted user content: %s\n' "$entry" >&2
            return 1
        }
    done <<<"$status"
}

orangepi_prepare_source() {
    local source_preexisting=0
    [[ ! -d $LINUX_SRC_DIR/.git ]] || source_preexisting=1
    info "Cloning Linux source repository $LINUX_REPO_URL -> $LINUX_SRC_DIR"
    clone_repository "$LINUX_REPO_URL" "$LINUX_SRC_DIR"
    orangepi_configure_source_excludes "$LINUX_SRC_DIR"
    ((source_preexisting == 0)) || orangepi_assert_safe_source_tree "$LINUX_SRC_DIR"
    info "Checking out Linux ref ${LINUX_REF}"
    checkout_ref "$LINUX_SRC_DIR" "$LINUX_REF"
    if [[ -d $LINUX_PATCH_DIR ]]; then
        info "Applying patches..."
        apply_patches "$LINUX_PATCH_DIR" "$LINUX_SRC_DIR"
    fi
}

orangepi_run_upstream() (
    local build_opt=$1
    cd "$LINUX_SRC_DIR"
    info "Starting Orange Pi ${build_opt} build"
    ./build.sh BOARD=orangepi5plus BRANCH=current BUILD_OPT="$build_opt" RELEASE=jammy \
        BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no
)

orangepi_configure_gpt() {
    local config="$LINUX_SRC_DIR/userpatches/lib.config"
    info "Configuring GPT partition layout (EFI + FAT32 boot + ext4 rootfs)"
    mkdir -p "$(dirname -- "$config")"
    cat >"$config" <<'EOF'
IMAGE_PARTITION_TABLE=gpt
BOOTFS_TYPE=fat
BOOTSIZE=1024
EOF
}

orangepi_compile_chosen_overlay() {
    local source=$1 output=$2
    dtc -@ -Wno-chosen_node_is_root -I dts -O dtb -o "$output" "$source"
}

orangepi_select_rootfs_archive() {
    local cache_dir="$LINUX_SRC_DIR/external/cache/rootfs" marker archive
    local -a candidates=()
    [[ -d $cache_dir ]] || { warn "Orange Pi rootfs cache directory not found: $cache_dir"; return 1; }
    while IFS= read -r -d '' marker; do
        archive=${marker%.current}
        [[ -f $archive ]] && candidates+=("$archive")
    done < <(find "$cache_dir" -maxdepth 1 -type f \
        -name 'jammy-minimal-arm64.*.tar.lz4.current' -print0 | LC_ALL=C sort -z)
    ((${#candidates[@]} == 1)) || {
        warn "Expected exactly one current Orange Pi Jammy rootfs archive, found ${#candidates[@]}"
        return 1
    }
    printf '%s\n' "${candidates[0]}"
}

orangepi_restore_archive_ownership() {
    local archive=$1 image=$2 work=$3 manifest commands path uid gid quoted output
    mkdir -p "$work"
    manifest="$work/owners"
    commands="$work/owners.debugfs"
    if ! lz4 -dc -- "$archive" | python3 -c '
import sys
import tarfile

with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
    for member in archive:
        name = member.name
        while name.startswith("./"):
            name = name[2:]
        name = name.rstrip("/")
        path = "/" + name if name and name != "." else "/"
        if any(ord(char) < 32 or ord(char) == 127 for char in path):
            raise SystemExit("unsafe ownership path")
        record = (path + "\0" + str(member.uid) + "\0" + str(member.gid) + "\0").encode(
            "utf-8", "surrogateescape"
        )
        sys.stdout.buffer.write(record)
' >"$manifest"; then
        return 1
    fi
    : >"$commands"
    while IFS= read -r -d '' path &&
          IFS= read -r -d '' uid &&
          IFS= read -r -d '' gid; do
        [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1
        quoted=$(_rootfs_debugfs_quote "$path") || return 1
        printf 'set_inode_field %s uid %s\nset_inode_field %s gid %s\n' \
            "$quoted" "$uid" "$quoted" "$gid" >>"$commands"
    done <"$manifest"
    output=$(_rootfs_run_tool 0 debugfs -w -f "$commands" "$image") || return 1
    [[ $output != *'File not found'* && $output != *'Command not found'* ]] || return 1
}

orangepi_restore_archive_security_xattrs() {
    local archive=$1 image=$2 work=$3 manifest path attribute value_file quoted_path quoted_value
    mkdir -p "$work"
    manifest="$work/manifest"
    if ! lz4 -dc -- "$archive" | python3 -c '
import os
import re
import sys
import tarfile

output = os.path.abspath(sys.argv[1])
index = 0
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
    for member in archive:
        name = member.name
        while name.startswith("./"):
            name = name[2:]
        if not name or name == ".":
            continue
        for key, value in sorted(member.pax_headers.items()):
            prefix = "SCHILY.xattr."
            if not key.startswith(prefix):
                continue
            attribute = key[len(prefix):]
            if not attribute.startswith("security."):
                continue
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", attribute):
                raise SystemExit("unsafe security xattr name")
            path = "/" + name
            if any(ord(char) < 32 or ord(char) == 127 for char in path):
                raise SystemExit("unsafe security xattr path")
            value_path = os.path.join(output, f"value.{index}")
            with open(value_path, "wb") as stream:
                stream.write(value.encode("utf-8", "surrogateescape"))
            record = (path + "\0" + attribute + "\0" + value_path + "\0").encode(
                "utf-8", "surrogateescape"
            )
            sys.stdout.buffer.write(record)
            index += 1
' "$work" >"$manifest"; then
        return 1
    fi
    while IFS= read -r -d '' path &&
          IFS= read -r -d '' attribute &&
          IFS= read -r -d '' value_file; do
        [[ -f $value_file && $attribute =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
        _rootfs_debugfs_stat "$image" "$path" required >/dev/null || return 1
        quoted_path=$(_rootfs_debugfs_quote "$path") || return 1
        quoted_value=$(_rootfs_debugfs_quote "$value_file") || return 1
        _rootfs_run_tool 0 debugfs -w -R \
            "ea_set -f ${quoted_value} ${quoted_path} ${attribute}" "$image" >/dev/null || return 1
    done <"$manifest"
}

orangepi_build_guest_rootfs() (
    local archive=$1 output=$2 work tree image overlay_parent outer_overlay guest_overlay
    local reserve pending_bytes pending_inodes lock_fd output_dir output_base publish=
    for tool in debugfs du lz4 mke2fs python3 tar truncate; do
        command -v "$tool" >/dev/null 2>&1 || { warn "required tool not found: $tool"; return 1; }
    done
    [[ -f $archive && ! -L $archive ]] || { warn "rootfs archive not found: $archive"; return 1; }
    reserve=$(rootfs_parse_size_bytes "$ORANGEPI_GUEST_FREE_SIZE") || return 1
    mkdir -p "$(dirname -- "$output")" "${BUILD_DIR}/orangepi-rootfs"
    work=$(mktemp -d "${BUILD_DIR}/orangepi-rootfs/guest.XXXXXX") || return 1
    trap 'rm -rf -- "$work"; [[ -z ${publish:-} ]] || rm -f -- "$publish"; build_lock_release_all' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    tree="$work/tree"
    image="$work/rootfs.img"
    overlay_parent="$work/overlays"
    mkdir -p "$tree" "$overlay_parent"
    local guest_tests=$ORANGEPI_GUEST_TESTS
    [[ ${ROOTFS_GRAPH_BASE_ONLY:-0} != 1 ]] || guest_tests=none
    rootfs_builder_prepare_test_overlays aarch64 "$ORANGEPI_ROOTFS_TYPE" none \
        "$guest_tests" "$overlay_parent" outer_overlay guest_overlay || return 1
    mkdir -p "$guest_overlay/etc/systemd/system/serial-getty@ttyS0.service.d"
    cat >"$guest_overlay/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStartPre=/bin/sh -c 'exec /bin/sleep 10'
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin root %I $TERM
Type=idle
EOF
    _rootfs_builder_normalize_overlay_seconds "$guest_overlay" || return 1
    bash -euo pipefail -c '
        archive=$1
        tree=$2
        image=$3
        lz4 -dc -- "$archive" | tar -xpf - --no-same-owner --xattrs \
            --xattrs-exclude="security.*" -C "$tree"
        read -r root_bytes _ < <(du -sb -- "$tree")
        size=$((root_bytes + root_bytes / 3 + 268435456))
        ((size >= 536870912)) || size=536870912
        size=$((((size + 1048575) / 1048576) * 1048576))
        truncate -s "$size" -- "$image"
        mke2fs -q -t ext4 -F -L orangepi-rootfs -O ^orphan_file,^metadata_csum_seed \
            -d "$tree" "$image"
    ' _ "$archive" "$tree" "$image" || return 1
    orangepi_restore_archive_ownership "$archive" "$image" "$work/ownership" || return 1
    orangepi_restore_archive_security_xattrs "$archive" "$image" "$work/security-xattrs" || return 1
    _rootfs_check_clean "$image" || return 1
    read -r pending_bytes pending_inodes < <(rootfs_overlay_capacity_stats "$guest_overlay") || return 1
    _rootfs_resize_for_capacity_in_place "$image" "$pending_bytes" "$reserve" "$pending_inodes" || return 1
    _rootfs_inject_tree_via_debugfs "$image" "$guest_overlay" || return 1
    _rootfs_compact_in_place "$image" "$reserve" || return 1
    _rootfs_check_clean "$image" || return 1
    touch -r "$archive" "$image"
    output_dir=$(dirname -- "$output")
    output_base=$(basename -- "$output")
    build_lock_acquire lock_fd "${output}.lock" || return 1
    publish=$(mktemp "${output_dir}/.${output_base}.publish.XXXXXX") || return 1
    cp --preserve=all --reflink=auto --sparse=always -- "$image" "$publish" || return 1
    mv -T -- "$publish" "$output" || return 1
    publish=
    build_lock_release "$lock_fd"
)

orangepi_snapshot_images() {
    local image_dir=$1 manifest=$2 directory base temporary image_path canonical sum size mtime
    directory=$(dirname -- "$manifest")
    base=$(basename -- "$manifest")
    mkdir -p "$directory"
    temporary=$(mktemp "${directory}/.${base}.XXXXXX") || return 1
    : >"$temporary"
    if [[ -d $image_dir ]]; then
        while IFS= read -r -d '' image_path; do
            [[ $image_path != *[$'\t\n\r']* ]] || { rm -f "$temporary"; return 1; }
            canonical=$(realpath -m -- "$image_path") || { rm -f "$temporary"; return 1; }
            sum=$(sha256sum -- "$image_path" | awk '{print $1}') || { rm -f "$temporary"; return 1; }
            size=$(stat -c %s -- "$image_path") || { rm -f "$temporary"; return 1; }
            mtime=$(stat -c %Y -- "$image_path") || { rm -f "$temporary"; return 1; }
            printf '%s\t%s\t%s\t%s\n' "$sum" "$size" "$mtime" "$canonical" >>"$temporary"
        done < <(find "$image_dir" -type f -name '*.img' -print0 | LC_ALL=C sort -z)
    fi
    mv -T -- "$temporary" "$manifest"
}

orangepi_select_built_image() {
    local image_dir=$1 before_manifest=$2 sum size mtime path old_sum
    local -a candidates=()
    local -A before=()
    [[ -f $before_manifest ]] || return 1
    while IFS=$'\t' read -r sum _ _ path; do
        [[ -z $path ]] || before[$path]=$sum
    done <"$before_manifest"
    while IFS= read -r -d '' path; do
        [[ $path != *[$'\t\n\r']* ]] || return 1
        path=$(realpath -m -- "$path") || return 1
        sum=$(sha256sum -- "$path" | awk '{print $1}') || return 1
        old_sum=${before[$path]-}
        [[ -n $old_sum && $sum == "$old_sum" ]] || candidates+=("$path")
    done < <(find "$image_dir" -type f -name '*.img' -print0 | LC_ALL=C sort -z)
    ((${#candidates[@]} == 1)) || {
        warn "Expected exactly one new or changed Orange Pi image, found ${#candidates[@]}"
        return 1
    }
    printf '%s\n' "${candidates[0]}"
}

finalize_linux_image() (
    local output platform_stage component
    local -a components=(linux u-boot arceos starry zephyr freertos ivc)
    [[ -f $ORANGEPI_BASE_IMAGE ]] || die "Orange Pi base image not found: ${ORANGEPI_BASE_IMAGE}"
    [[ -f $ORANGEPI_GUEST_ROOTFS ]] || die "Orange Pi guest rootfs not found: ${ORANGEPI_GUEST_ROOTFS}"
    mkdir -p "$PLATFORM_ROOTFS_DIR" "${BUILD_DIR}/orangepi-rootfs"
    platform_stage=$(mktemp -d "${BUILD_DIR}/orangepi-rootfs/platform.XXXXXX") || return 1
    trap 'rm -rf -- "$platform_stage"' EXIT
    for component in "${components[@]}"; do
        [[ -d $PLATFORM_IMAGES_DIR/$component ]] || {
            warn "Orange Pi all payload is missing: ${PLATFORM_IMAGES_DIR}/${component}"
            return 1
        }
        mkdir -p "$platform_stage/$component"
        cp -a --reflink=auto -- "$PLATFORM_IMAGES_DIR/$component/." \
            "$platform_stage/$component/" || return 1
    done
    output="${PLATFORM_ROOTFS_DIR}/orangepi-5-plus.img"
    rootfs_compose_disk_guest "$ORANGEPI_BASE_IMAGE" "$platform_stage" "$ORANGEPI_GUEST_ROOTFS" \
        aarch64 "$ORANGEPI_ROOTFS_TYPE" "$ORANGEPI_GUEST_FREE_SIZE" \
        "$ORANGEPI_OUTER_FREE_SIZE" "$output" prebuilt
)

# Output help information
usage() {
    printf 'Build supported OS for orangepi-5-plus development board with rootfs support\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/orangepi.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux kernel and DTB\n'
    printf '  uboot                             Build only U-Boot\n'
    printf '  rootfs                            Build the benchmark guest rootfs\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  starry                            Build only the StarryOS guest image\n'
    printf '  zephyr                            Build only the Zephyr guest image\n'
    printf '  ivc                               Build AXIVC Starry/Zephyr demo and benchmark payloads\n'
    printf '  freertos                          Build only the FreeRTOS guest image\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/orangepi.sh               # Build everything\n'
    printf '  scripts/orangepi.sh all           # Build everything\n'
    printf '  scripts/orangepi.sh linux         # Build Linux kernel and DTB\n'
    printf '  scripts/orangepi.sh rootfs        # Build benchmark guest rootfs\n'
    printf '  scripts/orangepi.sh ivc           # Build AXIVC demo/benchmark payloads\n'
}

build_uboot() {
    local uboot_images_dir="${PLATFORM_IMAGES_DIR}/u-boot"

    orangepi_validate_uboot_workdir
    info "Building U-Boot for Orange Pi 5..."
    chmod +x "${UBOOT_SCRIPT}"
    ORANGEPI_UBOOT_WORKDIR="$ORANGEPI_UBOOT_WORKDIR" bash "${UBOOT_SCRIPT}"

    mkdir -p "${uboot_images_dir}"
    cp -v "${ORANGEPI_UBOOT_WORKDIR}/out/u-boot-orangepi5-spi.bin" "${uboot_images_dir}/"
    success "U-Boot built successfully. Output: ${uboot_images_dir}/u-boot-orangepi5-spi.bin"
}

linux() {
    local linux_images_dir="${PLATFORM_IMAGES_DIR}/linux"
    local chosen_overlay_dts="${LINUX_PATCH_DIR}/orangepi-5-plus-chosen-overlay.dts"
    local chosen_overlay_dtbo="${linux_images_dir}/orangepi-5-plus-chosen.dtbo"
    if orangepi_linux_is_clean "$@"; then
        info "Cleaning Orange Pi Linux artifacts"
        rm -rf -- "$linux_images_dir"
        return
    fi
    orangepi_prepare_source
    orangepi_run_upstream kernel
    mkdir -p "$linux_images_dir"
    copy_required "$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/Image" \
        "$linux_images_dir/orangepi-5-plus"
    copy_required "$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb" \
        "$linux_images_dir/orangepi-5-plus.dtb"
    if [[ -f $chosen_overlay_dts ]]; then
        orangepi_compile_chosen_overlay "$chosen_overlay_dts" "$chosen_overlay_dtbo"
        fdtoverlay -i "$linux_images_dir/orangepi-5-plus.dtb" \
            -o "$linux_images_dir/orangepi-5-plus.dtb" "$chosen_overlay_dtbo"
        rm -f -- "$chosen_overlay_dtbo"
    fi
}

rootfs() (
    local archive lock_fd
    if orangepi_linux_is_clean "$@"; then
        info "Cleaning Orange Pi guest rootfs"
        trap 'build_lock_release_all' EXIT
        build_lock_acquire lock_fd "${ORANGEPI_GUEST_ROOTFS}.lock" || return 1
        rm -f -- "$ORANGEPI_GUEST_ROOTFS"
        build_lock_release "$lock_fd"
        trap - EXIT
        return
    fi
    orangepi_prepare_source
    orangepi_run_upstream rootfs
    archive=$(orangepi_select_rootfs_archive) || return 1
    orangepi_build_guest_rootfs "$archive" "$ORANGEPI_GUEST_ROOTFS"
)

orangepi_build_base_image() (
    local before_images selected_image
    orangepi_prepare_source
    orangepi_configure_gpt
    before_images=$(mktemp "${BUILD_DIR}/orangepi-images-before.XXXXXX") || return 1
    trap 'rm -f -- "$before_images"' EXIT
    orangepi_snapshot_images "$LINUX_SRC_DIR/output/images" "$before_images"
    orangepi_run_upstream image
    selected_image=$(orangepi_select_built_image "$LINUX_SRC_DIR/output/images" "$before_images") || return 1
    mkdir -p "$(dirname -- "$ORANGEPI_BASE_IMAGE")"
    rootfs_publish_target "$selected_image" "$ORANGEPI_BASE_IMAGE"
    chmod 0666 "$ORANGEPI_BASE_IMAGE"
    rm -f -- "$before_images"
    trap - EXIT
)

orangepi_clean_final_image() (
    local output="${PLATFORM_ROOTFS_DIR}/orangepi-5-plus.img" output_lock base_lock lock_fd1 lock_fd2
    local output_dir output_base legacy_lock
    info "Cleaning Orange Pi final image"
    mkdir -p "$(dirname -- "$output")" "$(dirname -- "$ORANGEPI_BASE_IMAGE")"
    output_lock=$(realpath -m -- "${output}.lock") || return 1
    base_lock=$(realpath -m -- "${ORANGEPI_BASE_IMAGE}.lock") || return 1
    [[ $output_lock != "$base_lock" ]] || {
        printf 'Orange Pi base and final image must use different paths: %s\n' "$output" >&2
        return 1
    }
    trap '
        if [[ -n ${lock_fd2:-} ]]; then build_lock_release "$lock_fd2" 2>/dev/null || true; fi
        if [[ -n ${lock_fd1:-} ]]; then build_lock_release "$lock_fd1" 2>/dev/null || true; fi
    ' EXIT
    if [[ $output_lock < $base_lock ]]; then
        build_lock_acquire lock_fd1 "$output_lock" || return 1
        build_lock_acquire lock_fd2 "$base_lock" || return 1
    else
        build_lock_acquire lock_fd1 "$base_lock" || return 1
        build_lock_acquire lock_fd2 "$output_lock" || return 1
    fi
    rm -f -- "$output" "$ORANGEPI_BASE_IMAGE" "${output}.lock" "${ORANGEPI_BASE_IMAGE}.lock"
    output_dir=$(dirname -- "$output")
    output_base=$(basename -- "$output")
    while IFS= read -r -d '' legacy_lock; do
        rm -f -- "$legacy_lock" || return 1
    done < <(find "$output_dir" -maxdepth 1 -type f \
        -name ".${output_base}.disk.*.lock" -print0)
    build_lock_release "$lock_fd2"
    build_lock_release "$lock_fd1"
    lock_fd2=
    lock_fd1=
    trap - EXIT
)

arceos() {
    local arceos_images_dir="${PLATFORM_IMAGES_DIR}/arceos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building ArceOS using common arceos.sh script"
    else
        info "Cleaning ArceOS using common arceos.sh script"
    fi
    bash "${SCRIPT_DIR}/../os/arceos.sh" aarch64-dyn --images-dir "${arceos_images_dir}" --image-name orangepi-5-plus "$@"
}

starry() {
    local starry_images_dir="${PLATFORM_IMAGES_DIR}/starry"
    local starry_release_images_dir="${ROOT_DIR}/IMAGES/orangepi-5-plus-starry"

    if [[ "$@" != *"clean"* ]]; then
        info "Building StarryOS using common starry.sh script"
        bash "${SCRIPT_DIR}/../os/starry.sh" orangepi-5-plus \
            --images-dir "${starry_images_dir}" \
            --release-images-dir "${starry_release_images_dir}" \
            --image-name orangepi-5-plus "$@"
    else
        info "Cleaning StarryOS using common starry.sh script"
        bash "${SCRIPT_DIR}/../os/starry.sh" clean \
            --images-dir "${starry_images_dir}" \
            --release-images-dir "${starry_release_images_dir}"
    fi
}

zephyr() {
    local zephyr_images_dir="${PLATFORM_IMAGES_DIR}/zephyr"

    if [[ "$@" != *"clean"* ]]; then
        info "Building Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/../os/zephyr.sh" orangepi-5-plus --images-dir "${zephyr_images_dir}" "$@"
    else
        info "Cleaning Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/../os/zephyr.sh" orangepi-5-plus clean --images-dir "${zephyr_images_dir}"
    fi
}

freertos() {
    local freertos_images_dir="${PLATFORM_IMAGES_DIR}/freertos"

    if [[ "$@" != *"clean"* ]]; then
        info "Building FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/../os/freertos.sh" orangepi-5-plus --images-dir "${freertos_images_dir}" --image-name "orangepi-5-plus" "$@"
    else
        info "Cleaning FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/../os/freertos.sh" orangepi-5-plus clean --images-dir "${freertos_images_dir}" --image-name "orangepi-5-plus"
    fi
}

ivc() {
    info "Building AXIVC Starry/Zephyr demo and benchmark payloads"
    bash "${SCRIPT_DIR}/../apps/ivc-rk3588.sh" "$@"
}

all() {
    local status=0

    # Linux and rootfs share one upstream checkout, so keep those stages
    # sequential. The remaining stages use independent source/work trees.
    linux "$@" || status=1
    rootfs "$@" || status=1
    local parallel_status restore_errexit=0
    [[ $- != *e* ]] || restore_errexit=1
    set +e
    run_parallel_functions "all" uboot arceos starry zephyr freertos -- "$@"
    parallel_status=$?
    if ((restore_errexit)); then set -e; fi
    if ((parallel_status != 0)); then
        status=1
        warn "Some Orange Pi platform targets failed; continuing with AXIVC payload build"
    fi

    ivc "$@" || status=1
    if ((status == 0)); then
        orangepi_build_base_image || status=1
    fi
    if ((status == 0)); then
        finalize_linux_image || status=1
    fi
    return "${status}"
}

uboot() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building U-Boot..."
    else
        info "Cleaning U-Boot build artifacts..."
        orangepi_validate_uboot_workdir
        rm -rf "$ORANGEPI_UBOOT_WORKDIR" "${PLATFORM_IMAGES_DIR}/u-boot"
        return
    fi
    build_uboot
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "${SCRIPT_DIR}/../lib/platform-log.sh"
    platform_log_init "$@"
    cmd="${1:-}"
    if [[ -z "${cmd}" ]]; then
        cmd="all"
    else
        shift
    fi
    if [[ "${cmd}" =~ ^(all|clean)$ ]]; then
        LOG_CREATE_DEFAULT_FILE="${LOG_CREATE_DEFAULT_FILE:-0}"
    fi
    source "${SCRIPT_DIR}/../lib/utils.sh"
    source "${SCRIPT_DIR}/../lib/rootfs.sh"
    source "${SCRIPT_DIR}/../lib/rootfs-compose.sh"
    source "${SCRIPT_DIR}/../lib/rootfs-disk.sh"
    case "$cmd" in
        -h|--help|help)
            usage
            exit 0
            ;;
        linux)
            linux "$@"
            ;;
        uboot)
            uboot "$@"
            ;;
        rootfs)
            rootfs "$@"
            ;;
        arceos)
            arceos "$@"
            ;;
        starry)
            starry "$@"
            ;;
        zephyr)
            zephyr "$@"
            ;;
        freertos)
            freertos "$@"
            ;;
        ivc)
            ivc "$@"
            ;;
        all)
            all "$@"
            ;;
        clean)
            run_parallel_functions "clean" linux uboot rootfs orangepi_clean_final_image arceos starry zephyr freertos -- clean
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
fi
