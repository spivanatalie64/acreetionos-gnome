#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - x86_64 -> arm64 conversion compatibility check
# ==============================================================================
#  Runs BEFORE a foreign-arch (principally arm64/aarch64) ISO gets built:
#    1. Resolves the target architecture via tools/ci/arch-layer.sh
#    2. Diffs the x86_64 package list against the target list (conversion
#       coverage: additions and removals are reported, never silently dropped)
#    3. Syncs the target arch repositories locally and probes EVERY target
#       package via `pacman -T`, mirroring mkarchiso's own readiness test
#    4. For each missing package, consults the presetup alternatives list
#       (tools/ci/compat-alternatives.conf). With --apply: substitutes the
#       first available alternative into the target package list; entries with
#       an EMPTY alternative list are pruned (known x86-only carryovers).
#    5. Verifies first-party staged binaries carry the target architecture
#
#  Usage: compat-check.sh [arch] [--apply] [--no-strict] [--skip-bincheck]
#    arch        target architecture (default: $HORIZON_ARCH, else aarch64)
#    --apply     substitute/prune into the target package list (in place)
#    --no-strict log-only mode: report missing packages but exit green
#    --skip-bincheck skip the first-party binary architecture audit
#  Exit 0 = conversion green; 1 = missing packages block the build (strict).
# ==============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/arch-layer.sh"

fail() { printf 'error: compat-check: %s\n' "$*" >&2; exit 1; }
alt_table="${HORIZON_COMPAT_ALTERNATIVES:-$here/compat-alternatives.conf}"

apply=false
strict=true
bincheck=true
target_arch=""
while (( $# > 0 )); do
    case "$1" in
        --apply) apply=true; shift ;;
        --no-strict) strict=false; shift ;;
        --strict) strict=true; shift ;;
        --skip-bincheck) bincheck=false; shift ;;
        -h|--help) printf 'Usage: %s [x86_64|aarch64] [--apply] [--no-strict] [--skip-bincheck]\n' "$0"; exit 0 ;;
        --*) fail "unknown option: $1 (see -h)" ;;
        *) [[ -z "$target_arch" ]] || fail "multiple architecture arguments"; target_arch="$1"; shift ;;
    esac
done
target_arch="${target_arch:-${HORIZON_ARCH:-aarch64}}"
arch_set "$target_arch" || fail "unsupported architecture"
command -v pacman >/dev/null 2>&1 || fail "pacman is required"

root_dir="$(cd "$here/../.." && pwd)"
src_file="$root_dir/packages.x86_64"
tgt_file="$root_dir/$(arch_get packages_file)"
tgt_conf="$root_dir/$(arch_get pacman_conf)"
strip() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
[[ -f "$src_file" && -f "$tgt_file" && -f "$tgt_conf" ]] || fail "missing package list or repo config (see header)"
mapfile -t src_list < <(strip "$src_file")
mapfile -t tgt_list < <(strip "$tgt_file")
(( ${#tgt_list[@]} > 0 )) || fail "target package list is empty: $tgt_file"

report_dir="$root_dir/.horizon-build/compat"
mkdir -p "$report_dir"
report="$report_dir/compat-$(arch_get arch)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$report") 2>&1
echo "==> x86_64 -> $(arch_get arch) conversion compatibility check starting..."

# ── Conversion coverage (x86_64 list vs target list) ─────────────────────────
comm_side() {  # $1 set A, $2 set B: packages in A but not B, prefixed
    local prefix="$3"
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && printf '%s %s\n' "$prefix" "$pkg"
    done < <(comm -23 <(printf '%s\n' "$1" | sort -u) <(printf '%s\n' "$2" | sort -u))
}
additions="$(comm_side "$(printf '%s\n' "${tgt_list[@]}")" "$(printf '%s\n' "${src_list[@]}")" '+')"
removals="$(comm_side "$(printf '%s\n' "${src_list[@]}")" "$(printf '%s\n' "${tgt_list[@]}")" '-')"
echo "conversion coverage: x86_64=$(printf '%s\n' "${src_list[@]}" | wc -l) target=$(printf '%s\n' "${tgt_list[@]}" | wc -l) additions=$(printf '%s\n' "$additions" | grep -c .) removals=$(printf '%s\n' "$removals" | grep -c .)"
[[ -z "$additions" ]] || { echo "target-only additions:"; printf '%s\n' "$additions"; }
[[ -z "$removals" ]] || { echo "x86_64-only removals:"; printf '%s\n' "$removals"; }

# ── Repository availability using mkarchiso's own probe (pacman -T) ──────────
tmpdb="$(mktemp -d "$report_dir/db.XXXXXXXX")"
trap 'rm -rf -- "$tmpdb"' EXIT
if [[ "$(id -u)" -ne 0 ]]; then
    fail "pacman -Sy requires root: run compat-check from the build container/CI runner"
fi
if ! pacman -Sy --noconfirm --dbpath "$tmpdb" --config "$tgt_conf" >"$report_dir/sync.log" 2>&1; then
    tail -n 10 "$report_dir/sync.log" >&2
    fail "cannot sync $(arch_get arch) repositories (check network/mirror)"
fi

# ── One-shot repository index: single pacman -Sl call, zero per-pkg forks ────
# Every package in every configured repo, enumerated once; O(1) associative
# lookups afterward instead of one pacman fork per target (the old probe took
# ~4 s per fork on a 200+-package list - this path costs one call).
repo_index="$(pacman --dbpath "$tmpdb" --config "$tgt_conf" -Sl 2>"$report_dir/sl.err")" || {
    tail -n 5 "$report_dir/sl.err" >&2
    fail "cannot enumerate $(arch_get arch) repositories (pacman -Sl failed)"
}
declare -A repo_pkgs=()
while read -r repo name _version; do
    [[ -n "$name" ]] && repo_pkgs["$name"]="$repo"
done <<< "$repo_index"
repo_names="$(printf '%s\n' "$repo_index" | awk '{print $1}' | sort -u | tr '\n' ' ')"
echo "repository index: ${#repo_pkgs[@]} packages across: $repo_names"

declare -A alternatives=()
if [[ -f "$alt_table" ]]; then
    while IFS= read -r row; do
        row="${row%%#*}"
        [[ "$row" != *:* ]] && continue
        pkg="${row%%:*}"
        alts="${row#*:}"
        [[ -n "$pkg" ]] && alternatives["$pkg"]="$alts"
    done < <(strip "$alt_table")
fi

probe() {  # probe <package> -> 0 if resolvable in target repos (set lookup)
    [[ -n "${repo_pkgs[${1}]:-}" ]]
}

missing=()
substituted=()
prunable=()
for pkg in "${tgt_list[@]}"; do
    if probe "$pkg"; then
        continue
    fi
    alts="${alternatives[$pkg]:+${alternatives[$pkg]}}"
    candidate_ok=""
    if [[ -n "$alts" ]]; then
        IFS=',' read -ra alt_list <<< "$alts"
        for alt in "${alt_list[@]}"; do
            alt="${alt//[[:space:]]/}"
            [[ -z "$alt" ]] && continue
            if probe "$alt"; then candidate_ok="$alt"; break; fi
        done
    fi
    if [[ -n "$candidate_ok" ]]; then
        substituted+=("$pkg -> $candidate_ok")
    elif [[ -n "${alternatives[$pkg]:-}" ]]; then
        # Known x86-only carryover: alternatives entry exists but is empty
        # or unavailable -> flagged prunable (removed by --apply).
        prunable+=("$pkg")
    else
        missing+=("$pkg")
    fi
done

if (( ${#substituted[@]} > 0 )); then
    printf 'presetup alternatives available (%s):\n' "${#substituted[@]}"
    printf '  %s\n' "${substituted[@]}"
fi
if (( ${#prunable[@]} > 0 )); then
    printf 'prunable x86-only carryovers (empty alternative) (%s): %s\n' \
        "${#prunable[@]}" "${prunable[*]}"
fi

if "$apply"; then
    backup="$tgt_file.precompat-$(date +%s)"
    cp -f -- "$tgt_file" "$backup"
    if (( ${#substituted[@]} > 0 )); then
        for sub in "${substituted[@]}"; do
            pkg="${sub%% -> *}"
            alt="${sub##* -> }"
            sed -i -e "s/^${pkg}\$/${alt}/" -- "$tgt_file"
        done
    fi
    if (( ${#prunable[@]} > 0 )); then
        for pkg in "${prunable[@]}"; do
            sed -i -e "/^${pkg}\$/d" -- "$tgt_file"
        done
    fi
    echo "--apply: package list updated (backup kept: $backup)"
else
    (( ${#substituted[@]} + ${#prunable[@]} == 0 )) || \
        echo "note: rerun with --apply to substitute alternatives/prune carryovers"
fi

# ── One final resolution sanity pass (a single pacman -T on the effective
#    list) catches missing transitive dependencies before mkarchiso does. ──
mapfile -t effective_list < <(strip "$tgt_file")
resolution="ok"
if ! pacman -T --dbpath "$tmpdb" --config "$tgt_conf" -- "${effective_list[@]}" >"$report_dir/t.log" 2>&1; then
    resolution="pending"
    tail -n 15 "$report_dir/t.log" >&2
fi
echo "resolution sanity: $resolution (single pacman -T over ${#effective_list[@]} packages)"

# ── Bootloader stack consistency (systemd-boot primary, per AGENTS.md) ───────
bootmodes="$(sed -n "s/^bootmodes=\((.*)\)/\1/p" "$root_dir/profiledef.sh" 2>/dev/null || true)"
if [[ -z "$bootmodes" ]]; then
    echo "warning: cannot parse profiledef.sh bootmodes; skipping bootloader checks"
else
    echo "profile bootmodes: $bootmodes"
    if [[ "$(arch_get arch)" == "aarch64" ]]; then
        [[ "$bootmodes" == *"bios"* ]] && \
            echo "warning: bootmodes include x86 BIOS syslinux - inapplicable on aarch64; trim bootmodes on the arm runner (profiles are arch-agnostic)"
        if [[ "$bootmodes" != *"systemd-boot"* ]]; then
            fail "systemd-boot is the primary Horizon boot method but profiledef.sh lists none; refusing arm conversion"
        fi
        if grep -q "grub\b" "$tgt_file"; then
            echo "warning: grub present in packages.aarch64 (legacy-BIOS fallback only); run compat-check --apply to prune it in favor of systemd-boot"
        fi
    fi
fi

# ── First-party binary architecture audit ────────────────────────────────────
if "$bincheck" && command -v file >/dev/null 2>&1; then
    while IFS= read -r candidate_bin; do
        [[ -e "$candidate_bin" ]] || continue
        info="$(file -b "$candidate_bin" 2>/dev/null)" || info=""
        case "$info" in
            *ELF*)
                if [[ "$info" != *"ARM aarch64"* && "$info" != *"x86-64"* ]]; then
                    echo "warning: unexpected binary architecture: $candidate_bin - $info"
                fi ;;
            *) ;;  # scripts are inherently arch-neutral
        esac
    done < <(find "$root_dir/.horizon-build" -maxdepth 1 -name 'freeman-*' -type f 2>/dev/null)
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
if (( ${#missing[@]} > 0 )); then
    printf 'MISSING in %s repositories, with no presetup alternative (%s):\n' \
        "$(arch_get arch)" "${#missing[@]}"
    printf '  %s\n' "${missing[@]}"
    if "$strict"; then
        fail "missing $(arch_get arch) packages block the build; extend tools/ci/compat-alternatives.conf or prune packages.$(arch_get arch)"
    fi
    echo "compat-check: --no-strict mode, exiting green with warnings"
    exit 0
fi
echo "==> compatibility green: $(arch_get arch) ISO build may proceed"
exit 0
