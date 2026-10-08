#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - architecture conversion layer (sourceable)
# ==============================================================================
#  Single source of truth for per-architecture build and boot-test parameters.
#  Downstream scripts (build.sh, boot-test.sh, CI, cross-compile helpers)
#  resolve everything through arch_* accessors instead of hardcoding x86_64.
#
#  Record format (colon-separated per arch, columns in header order):
#      arch:qemu_bin:qemu_machine:serial_tty:kernel_regex:initramfs_regex:
#      pacman_conf:packages_file:cross_prefix:strategies:bitness
#
#  API (each takes an arch, defaulting to $HORIZON_ARCH):
#      arch_supported [arch]           -> 0/1
#      arch_list                       -> canonical arch names
#      arch_get FIELD [arch]           -> value
#      arch_set ARCH                   -> sets HORIZON_ARCH, validates, normalizes
#      arch_is_64bit [arch]            -> 0/1
#      arch_gcc_triple [arch]          -> cross compiler triple ("-" = native)
#      arch_strategy [arch]            -> "native" | "cross" | "native-and-cross"
#
#  Every row MUST keep exactly 11 columns; ARCH_LAYER_FIELDS is the header.
# ==============================================================================

ARCH_LAYER_FIELDS="arch:qemu_bin:qemu_machine:serial_tty:kernel_regex:initramfs_regex:pacman_conf:packages_file:cross_prefix:strategies:bitness"

#                              arch     qemu_bin              qemu_machine  serial_tty  kernel_regex                                             initramfs_regex                                pacman_conf          packages_file       cross_prefix             strategies        bitness
ARCH_TABLE=(
  'x86_64:qemu-system-x86_64:pc:ttyS0:^boot/vmlinuz-[^/]+$:^boot/initramfs-[^/]+\.(img|zst)$:pacman.conf:packages.x86_64:-:native-and-cross:64'
  'aarch64:qemu-system-aarch64:virt:ttyAMA0:^boot/(Image[^/]*|vmlinuz-[^/]+)$:^boot/initramfs-[^/]+\.(img|zst|lz4)$:pacman-aarch64.conf:packages.aarch64:aarch64-linux-gnu-:native-and-cross:64'
)

arch_get() {
    local field="$1" arch="${2:-${HORIZON_ARCH:-}}"
    local idx=""
    local pair
    for pair in \
        arch=0 qemu_bin=1 qemu_machine=2 \
        serial_tty=3 kernel_regex=4 initramfs_regex=5 \
        pacman_conf=6 packages_file=7 \
        cross_prefix=8 strategies=9 bitness=10
    do
        [[ "${pair%%=*}" == "$field" ]] && { idx="${pair##*=}"; break; }
    done
    [[ -n "$idx" ]] || { printf 'error: arch-layer: unknown field: %s\n' "$field" >&2; return 1; }
    [[ -n "$arch" ]] || { printf 'error: arch-layer: no architecture given\n' >&2; return 1; }
    local row
    for row in "${ARCH_TABLE[@]}"; do
        local -a cols
        IFS=':' read -ra cols <<< "$row"
        [[ "${cols[0]}" == "$arch" ]] || continue
        echo "${cols[$idx]}"
        return 0
    done
    printf 'error: arch-layer: unsupported architecture: %s\n' "$arch" >&2
    return 1
}

arch_list() {
    local row
    for row in "${ARCH_TABLE[@]}"; do
        local -a cols
        IFS=':' read -ra cols <<< "$row"
        printf '%s\n' "${cols[0]}"
    done
}

arch_supported() {
    local arch="${1:-${HORIZON_ARCH:-}}"
    for candidate in $(arch_list); do
        [[ "$candidate" == "$arch" ]] && return 0
    done
    return 1
}

arch_is_64bit() {
    [[ "$(arch_get bitness "${1:-${HORIZON_ARCH:-}}")" == "64" ]]
}

arch_gcc_triple() {
    local prefix
    prefix="$(arch_get cross_prefix "${1:-${HORIZON_ARCH:-}}")"
    if [[ -n "$prefix" && "$prefix" != "-" ]]; then
        printf '%s\n' "${prefix%-}"
        return 0
    fi
    printf '%s\n' '-'
    return 1
}

# arch_set: normalize uname-style spellings and fix the active architecture.
arch_set() {
    local arch="${1:-}"
    case "$arch" in
        amd64|x64) arch="x86_64" ;;
        arm64|aarch64_be) arch="aarch64" ;;
        "")
            printf 'error: arch-layer: arch_set requires an architecture\n' >&2
            printf 'supported: %s\n' "$(arch_list | tr '\n' ' ')" >&2
            return 1 ;;
    esac
    if ! arch_supported "$arch"; then
        printf 'error: arch-layer: unsupported architecture: %s\n' "$arch" >&2
        printf 'supported: %s\n' "$(arch_list | tr '\n' ' ')" >&2
        return 1
    fi
    HORIZON_ARCH="$arch"
    export HORIZON_ARCH
}

arch_strategy() {
    arch_get strategies "${1:-${HORIZON_ARCH:-}}"
}
