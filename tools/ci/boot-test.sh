#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - ISO boot test matrix (QEMU, KVM where available)
# ==============================================================================
#  Boots the produced ISO under every CPU model from cpu-models.conf (one per
#  Intel/AMD generation plus generic qemu64/amd64/x86_64) and under the
#  configured hypervisor accelerators. Runs inside the privileged build
#  container (pass /dev/kvm through) or directly on a host; without /dev/kvm
#  everything falls back to TCG emulation, which is much slower per boot.
#
#  Usage:
#    boot-test.sh --iso PATH/image.iso [options]
#  Options:
#    --arch ARCH         guest architecture: x86_64 (default) or aarch64
#    --timeout SECONDS   per-boot watchdog (default: 420)
#    --cpus all          every model qemu reports via -cpu help (slow)
#    --cpus FILE         custom matrix file (default: cpu-models.conf)
#    --hypervisors LIST  kvm,tcg,xen (default: auto-detect; xen=dom0 only)
#    --verbose           print qemu commands and serial-log diagnostics
#  Exit 0 when every boot test passed; 1 when any failed.
# ==============================================================================
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Architecture conversion layer: single source of per-arch truth
source "$here/arch-layer.sh"

fail() { printf 'error: boot-test: %s\n' "$*" >&2; exit 125; }
usage_hint='usage: boot-test.sh --iso PATH/image.iso [--arch x86_64|aarch64] [--timeout N] [--cpus all|FILE] [--hypervisors kvm,tcg,xen] [--verbose]'

iso=""
iso_arch="x86_64"
timeout_s=420
matrix_file="$(dirname "${BASH_SOURCE[0]}")/cpu-models.conf"
hypervisors=""
verbose=0
cpus_all=0

while (( $# > 0 )); do
    case "$1" in
        --iso) [[ -f "${2:-}" && "${2:?}" == *.iso ]] || fail "--iso requires an existing .iso ($usage_hint)"; iso="$2"; shift 2 ;;
        --arch) case "${2:-}" in
                    x86_64|aarch64) iso_arch="$2" ;;
                    *) fail "unsupported architecture: $2 (x86_64 or aarch64)" ;;
                esac; shift 2 ;;
        --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || fail "--timeout wants seconds"; timeout_s="$2"; shift 2 ;;
        --cpus) case "${2:-}" in
                    all) cpus_all=1 ;;
                    *) [[ -f "${2:-}" ]] || fail "no such cpu matrix: $2"; matrix_file="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" ;;
                esac; shift 2 ;;
        --hypervisors) hypervisors="${2:-}"; shift 2 ;;
        --verbose) verbose=1; shift ;;
        *) fail "unknown argument: $1 ($usage_hint)" ;;
    esac
done
[[ -n "$iso" ]] || fail "--iso PATH is required ($usage_hint)"
arch_set "$iso_arch" || exit 1
qemu_bin="$(arch_get qemu_bin)"
command -v "$qemu_bin" >/dev/null 2>&1 || fail "$qemu_bin is required"
command -v bsdtar >/dev/null 2>&1 || fail "bsdtar (libarchive) is required"

report_dir="$(dirname "$iso")/boot-test"
mkdir -p "$report_dir"
work_dir="$(mktemp -d "$PWD/boot-test-run.XXXXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

# ── Hypervisor auto-detect ───────────────────────────────────────────────────
if [[ -z "$hypervisors" ]]; then
    hypervisors=""
    # KVM only accelerates when host arch matches the guest arch.
    if [[ -w /dev/kvm && "$(uname -m)" == "$iso_arch" ]]; then
        hypervisors="kvm"
    fi
    hypervisors="${hypervisors:+$hypervisors,}tcg"
    # Xen guests need a dom0 with a working xl toolstack; anything else skips.
    if command -v xl >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]] && xl info >/dev/null 2>&1; then
        hypervisors="${hypervisors:+$hypervisors,}xen"
    fi
fi
if [[ "$verbose" == 1 ]]; then
    printf '==> Hypervisors under test: %s\n' "${hypervisors:-none}" >&2
fi
[[ -n "$hypervisors" ]] || fail "no hypervisors available to test with"

# ── Extract kernel+initramfs once; direct-boot gives serial logging ─────────
kernel_regex="$(arch_get kernel_regex)"
initramfs_regex="$(arch_get initramfs_regex)"
[[ -n "$kernel_regex" && -n "$initramfs_regex" ]] || fail "arch-layer must define kernel/initramfs regexes for $iso_arch"
mapfile -t payload < <(bsdtar -tf "$iso" | grep -E "$kernel_regex|$initramfs_regex" | sort -u)
[[ ${#payload[@]} -ge 2 ]] || fail "no kernel+initramfs payload found inside $iso"

bsdtar -x -C "$work_dir" -f "$iso" "${payload[@]}"
qemu_kernel="$work_dir/$(basename "${payload[0]}")"
qemu_initrd="$work_dir/$(basename "${payload[1]}")"

# ── CPU models ───────────────────────────────────────────────────────────────
qemu_cpu_help="$("$qemu_bin" -cpu help)"
if [[ "$iso_arch" == aarch64 ]]; then
    arm_matrix_file="$(dirname "$matrix_file")/cpu-models-aarch64.conf"
    (( cpus_all )) || [[ -f "$arm_matrix_file" ]] || fail "missing $arm_matrix_file for aarch64 testing"
    (( cpus_all )) && matrix_file="$arm_matrix_file"
fi
mapfile -t matrix < <(
    if (( cpus_all )); then
        printf '%s\n' "$qemu_cpu_help" | awk '/^ *[a-zA-Z0-9_-]+ / {print $2 "\tgeneric\t64\t"}'
    else
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$matrix_file" \
            | awk -F'\t' '{print $2 "\t" $1 "\t" $3 "\t" $4}'
    fi
)
(( ${#matrix[@]} > 0 )) || fail "empty CPU model matrix: $matrix_file"

# ── Boot test loop ───────────────────────────────────────────────────────────
passed=0
failed=0
failed_names=()
run_boot_test() {
    local hypervisor="$1" cpu_model="$2" cpu_vendor="$3" note="$4"
    local accel_args=( -accel )
    case "$hypervisor" in
        kvm) accel_args+=(kvm) ;;
        tcg) accel_args+=(tcg,thread=multi) ;;
        xen) accel_args+=(tcg); accel_args+=(-machine xenpvh) ;;
        *) fail "unknown hypervisor: $hypervisor" ;;
    esac
    local label="${cpu_vendor}/${cpu_model} on ${hypervisor}"
    local serial_log="$report_dir/${hypervisor}-${cpu_model}.log"
    local qemu_machine="$(arch_get qemu_machine)"
    local serial_tty="$(arch_get serial_tty)"
    local qemu_args=(
        -display none -no-reboot -monitor none -m 2048 -smp 2
        -M "$qemu_machine" -cpu "$cpu_model"
        -serial "file:$serial_log"
        -kernel "$qemu_kernel" -initrd "$qemu_initrd"
        -append "archisobasedir=arch archisodevice=/dev/sr0 console=$serial_tty"
        -cdrom "$iso"
    )
    [[ "$iso_arch" == aarch64 ]] && qemu_args+=(-device virtio-net-device,netdev=net0,netdev=net0 -netdev user,id=net0)
    qemu_args+=( "${accel_args[@]}" )
    (( verbose )) && printf '    %s %s\n' "$qemu_bin" "${qemu_args[*]}" >&2

    printf '[TEST] %-40s ... ' "$label"
    timeout --kill-after=30 "$timeout_s" \
        "$qemu_bin" "${qemu_args[@]}" >>"$serial_log" 2>&1 &
    local qemu_pid=$! waited=0 verdict="no boot marker within ${timeout_s}s"
    while (( waited < timeout_s )); do
        if grep -q 'Reached target Basic System\|login:\|Welcome to\|systemd version' "$serial_log" 2>/dev/null; then
            verdict="ok"; break
        fi
        if grep -q 'Kernel panic\|not a valid executable\|CPU feature' "$serial_log" 2>/dev/null; then
            verdict="kernel rejected this CPU model"; break
        fi
        sleep 2; waited=$((waited + 2))
        kill -0 "$qemu_pid" 2>/dev/null || break
    done
    if kill -0 "$qemu_pid" 2>/dev/null; then
        pkill -KILL -P "$qemu_pid" 2>/dev/null
        kill "$qemu_pid" 2>/dev/null || true
    fi
    wait "$qemu_pid" 2>/dev/null

    if [[ "$verdict" == "ok" ]]; then
        printf 'PASS (%ss)\n' "$waited"
        passed=$((passed + 1))
    else
        printf 'FAIL (%s)\n' "$verdict"
        (( verbose )) && tail -n 40 -- "$serial_log" >&2
        failed=$((failed + 1))
        failed_names+=("$label: $verdict")
    fi
    return 0
}

echo "==> Boot-testing $iso under ${#matrix[@]} CPU models × $hypervisors"
for entry in "${matrix[@]}"; do
    IFS=$'\t' read -r cpu_model cpu_vendor bitness note <<< "$entry"
    [[ -n "$cpu_model" ]] || continue
    if [[ "${bitness:-64}" == "32" ]]; then
        printf '[SKIP] %-40s (32-bit CPU vs %s ISO; %s)\n' "$cpu_vendor/$cpu_model" "$iso_arch" "$note"
        continue
    fi
    if [[ "$qemu_cpu_help" != *" $cpu_model "* ]]; then
        printf '[SKIP] %-40s (cpu model absent in this qemu build)\n' "$cpu_vendor/$cpu_model"
        continue
    fi
    for hypervisor in ${hypervisors//,/ }; do
        run_boot_test "$hypervisor" "$cpu_model" "$cpu_vendor" "$note"
    done
done

{
    echo "# AcreetionOS Horizon boot test report"
    echo "iso: $iso"
    echo "date: $(date -Is)"
    echo "passed: $passed   failed: $failed"
    for name in "${failed_names[@]:-}"; do
        [[ -z "$name" ]] || printf 'FAIL %s\n' "$name"
    done
} > "$report_dir/REPORT.txt"

printf '==> report: %s/REPORT.txt (%d passed, %d failed)\n' "$report_dir" "$passed" "$failed"
(( failed == 0 )) || exit 1
exit 0
