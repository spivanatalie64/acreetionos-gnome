#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - Complete One-Command Unified Build Script
# ==============================================================================
#  Builds all required components in order:
#    0. First-party toolchain (mkarchiso wrapper; freeman is built in step 2)
#    1. Patched GNOME 48 + XLibre desktop stack (into .horizon-build/repo)
#    2. Freeman package & image update utility (into airootfs/usr/local/bin)
#    3. Clean workspace & construct final AcreetionOS Horizon ISO image
#
#  Outside a container, build.sh provisions its own build environment in a
#  container (Dockerfile / build-deps.txt) and re-enters itself inside it, so
#  the host only needs a container runtime. Use -H to run on the host as-is.
#
#  --external SSH-HOST pushes the source to another machine over SSH, builds
#  there in a self-provisioned privileged podman (or docker) container, streams
#  the log back, and scp's the finished ISO images home.
# ==============================================================================
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

  --external HOST   Build on another machine over SSH (in a privileged
                    podman/docker container there) and scp the ISOs back.
                    Any host usable in ssh commands works, e.g. build@server
                    or an ssh config alias; ports/keys come from ssh config.
  --verbose         Verbose mode: trace shell commands and transfers.
  --security-gate   Run the alpha security gate first (tests, CVE scan over
                    the dependency trees, private issue, auto-patch).
  --boot-test       After ISO construction, boot the image in QEMU across
                    the CPU-generation matrix (tools/ci/cpu-models.conf).
  --with-multilib   Also produce a secondary ISO built against the 32-bit
                    (multilib) repositories.
  --alpha           Alpha-channel preset: --security-gate --boot-test
                    --with-multilib, performed in order.
  -p                Patched packages only (implies -f -i)
  -u                Freeman update utility only (implies -s -i)
  -s                Skip step 1: patched GNOME/XLibre packages
  -f                Skip step 2: Freeman utility
  -i                Skip step 3: ISO construction
  -r                Force Freeman rebuild (even if binary exists)
  -H                Host mode: build directly without the container
                    (also what build.sh uses internally inside the container)
  -n                Container mode: rebuild the image without layer cache
  -w DIR            ISO work directory           (default: ./work)
  -o DIR            ISO output directory         (default: ../ISO)
  -b DIR            Horizon build directory      (default: ./.horizon-build)
  -l LABEL          ISO volume label             (default: AcreetionOS-Horizon)
  -c CONF           pacman.conf                  (default: ./pacman.conf)
  -h                Show this help

  --security-gate   Run alpha-channel security gate first: suite tests, CVE
                    comparison of dependency trees, private issue, auto-patch.
  --arch ARCH       Target architecture via the conversion layer
                    (tools/ci/arch-layer.sh): x86_64 (default) or aarch64.
                    Foreign-arch ISO construction must run on a native runner;
                    the compile stage handles cross toolchains itself.
  --boot-test       After the main ISO builds, boot it in QEMU under the
                    CPU matrix (tools/ci/cpu-models.conf; KVM/T Xen where a
                    dom0 is available).
  --with-multilib   Also build a secondary ISO against the 32-bit (multilib)
                    repositories, labelled -32.
  --alpha           Alpha preset: --security-gate --boot-test --with-multilib.
  --external HOST   Build on another machine over SSH in a podman container
                    and scp returned ISOs back. (Compatible with --alpha.)
  --verbose         Trace shell/command flow.

The container environment (meson, ninja, cargo, archiso, ...) installs itself
from build-deps.txt; see Dockerfile and tools/container/setup-build-env.sh.
With --external the same self-provisioning happens on the remote machine.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HORIZON_BUILD_DIR="${HORIZON_BUILD_DIR:-$ROOT_DIR/.horizon-build}"
ISO_LABEL="${ISO_LABEL:-AcreetionOS-Horizon}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
ISO_OUT_DIR="${ISO_OUT_DIR:-$ROOT_DIR/../ISO}"
PACMAN_CONF="${PACMAN_CONF:-$ROOT_DIR/pacman.conf}"
IMAGE_TAG="${HORIZON_CONTAINER_IMAGE:-horizon-build:latest}"
skip_patched="${HORIZON_SKIP_PATCHED_PACKAGES:-0}"
skip_freeman="${HORIZON_SKIP_FREEMAN:-0}"
skip_iso="${HORIZON_SKIP_ISO:-0}"
rebuild_freeman="${HORIZON_REBUILD_FREEMAN:-0}"
host_mode=0
no_cache=0
verbose=0
external_host=""
security_gate="${HORIZON_SECURITY_GATE:-0}"
boot_test="${HORIZON_BOOT_TEST:-0}"
with_multilib="${HORIZON_WITH_MULTILIB:-0}"
skip_compat=0
compat_check_only=0
# Architecture conversion layer (tools/ci/arch-layer.sh): canonical source of
# per-arch qemu/pacman/packages parameters. --arch or HORIZON_ARCH sets it.
horizon_arch="${HORIZON_ARCH:-x86_64}"
pac_conf_given=0

fail() { printf 'error: build.sh: %s\n' "$*" >&2; exit 1; }

# Long options first, then short ones for getopts.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose)   verbose=1; shift ;;
        --security-gate) security_gate=1; shift ;;
        --boot-test) boot_test=1; shift ;;
        --with-multilib) with_multilib=1; shift ;;
        --skip-compat) skip_compat=1; shift ;;
        --compat-check-only) compat_check_only=1; shift ;;
        --arch)      [[ $# -ge 2 ]] || fail "--arch requires an architecture argument"
                     horizon_arch="$2"; shift 2 ;;
        --arch=*)    horizon_arch="${1#*=}"; shift ;;
        --alpha)     security_gate=1; boot_test=1; with_multilib=1; echo "Alpha-channel preset enabled"; shift ;;
        --external)  [[ $# -ge 2 ]] || fail "--external requires a host argument"
                     external_host="$2"; shift 2 ;;
        --external=*) external_host="${1#*=}"; shift ;;
        --)          shift; break ;;
        --*)         fail "unknown long option: $1 (see -h)" ;;
        *)           break ;;
    esac
done
if (( verbose )); then set -x; fi

while getopts ":psfiuHnrho:b:l:c:h" opt; do
    case "$opt" in
        p) skip_freeman=1; skip_iso=1 ;;
        u) skip_patched=1; skip_iso=1 ;;
        s) skip_patched=1 ;;
        f) skip_freeman=1 ;;
        i) skip_iso=1 ;;
        r) rebuild_freeman=1 ;;
        H) host_mode=1 ;;
        n) no_cache=1 ;;
        w) mkdir -p "$OPTARG" && WORK_DIR="$(cd "$OPTARG" && pwd)" ;;
        o) mkdir -p "$OPTARG" && ISO_OUT_DIR="$(cd "$OPTARG" && pwd)" ;;
        b) mkdir -p "$OPTARG" && HORIZON_BUILD_DIR="$(cd "$OPTARG" && pwd)" ;;
        l) ISO_LABEL="$OPTARG" ;;
        c) [[ -f "$OPTARG" ]] || fail "no such pacman.conf: $OPTARG"
           PACMAN_CONF="$(cd "$(dirname "$OPTARG")" && pwd)/$(basename "$OPTARG")"
           pac_conf_given=1 ;;
        h) usage; exit 0 ;;
        \?) fail "unknown option: -$OPTARG (see -h)" ;;
        :) fail "option -$OPTARG requires an argument" ;;
    esac
done
shift $((OPTIND - 1))
(( $# == 0 )) || fail "unexpected positional arguments: $*"

# Resolve the architecture through the conversion layer after option parsing,
# so --arch wins over HORIZON_ARCH and per-arch defaults are applied once.
# shellcheck source=tools/ci/arch-layer.sh
source "$ROOT_DIR/tools/ci/arch-layer.sh"
arch_set "$horizon_arch" || fail "see --help for supported --arch values"
if (( ! pac_conf_given )); then
    per_arch_conf="$ROOT_DIR/$(arch_get pacman_conf)"
    [[ -f "$per_arch_conf" ]] || fail "missing per-arch pacman.conf: $per_arch_conf"
    PACMAN_CONF="$per_arch_conf"
fi
packages_file="$ROOT_DIR/$(arch_get packages_file)"
[[ -f "$packages_file" ]] || fail "missing per-arch package list: $packages_file"
# Patched GNOME 48 / XLibre packages exist only for the x86_64 pinned desktop;
# other architectures fall back to the stock upstream stack.
if [[ "$HORIZON_ARCH" != "x86_64" && "$skip_patched" != 1 ]]; then
    skip_patched=1
    echo "==> Architecture $HORIZON_ARCH: patched XLibre packages unavailable; skipping step 1"
fi
# ISO construction (mkarchiso/pacstrap) needs a native runner for the target;
# only the compile stage (e.g. cross freeman builds) supports foreign hosts.
if [[ "$HORIZON_ARCH" != "$(uname -m)" && "${skip_iso:-}" != 1 && "$host_mode" == 1 ]]; then
    fail "ISO construction for $HORIZON_ARCH requires a native $HORIZON_ARCH runner (see .github/workflows/build-iso-arm.yml); local hosts can compile only via the arch layer with -i"
fi

echo "===================================================================="
echo "  Starting AcreetionOS Horizon Full Build  (arch: $HORIZON_ARCH)"
echo "===================================================================="
echo "  Working directory: $ROOT_DIR"
echo "  Build directory:   $HORIZON_BUILD_DIR"
echo "  ISO Output:        $ISO_OUT_DIR"
echo "===================================================================="

# ------------------------------------------------------------------------------
# External leg: build in a self-provisioned privileged container on another
# machine, reached over SSH, and scp the finished ISOs back home. The remote
# end reuses this same script, so the remote environment sets itself up too.
# ------------------------------------------------------------------------------
if (( ! host_mode )) && [[ -n "$external_host" ]]; then
    command -v ssh >/dev/null 2>&1 || fail "ssh is required for --external"
    command -v scp >/dev/null 2>&1 || fail "scp is required for --external"
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$external_host" true \
        || fail "cannot reach $external_host via ssh (public-key auth expected)"

    # Everything below is evaluated on the remote side.
    remote_root='${HORIZON_EXTERNAL_ROOT:-$HOME/acreetionos-horizon}'
    remote_dir="$remote_root/repo"
    remote_iso="$remote_root/ISO"

    skip_env=()
    [[ "$skip_patched" == 1 ]] && skip_env+=(HORIZON_SKIP_PATCHED_PACKAGES=1)
    [[ "$skip_freeman" == 1 ]] && skip_env+=(HORIZON_SKIP_FREEMAN=1)
    [[ "$skip_iso" == 1 ]] && skip_env+=(HORIZON_SKIP_ISO=1)
    [[ "$rebuild_freeman" == 1 ]] && skip_env+=(HORIZON_REBUILD_FREEMAN=1)
    [[ "$security_gate" == 1 ]] && skip_env+=(HORIZON_SECURITY_GATE=1)
    [[ "$boot_test" == 1 ]] && skip_env+=(HORIZON_BOOT_TEST=1)
    [[ "$with_multilib" == 1 ]] && skip_env+=(HORIZON_WITH_MULTILIB=1)
    skip_env+=(HORIZON_ARCH="$HORIZON_ARCH")

    echo "==> Pushing source tree to $external_host..."
    ssh "$external_host" "mkdir -p '$remote_dir'"
    tar ${verbose:+--verbose} -cz --exclude=./work --exclude=./.horizon-build \
            --exclude=./out --exclude=./.git --exclude='*/node_modules' \
            --exclude='*/target' \
            -C "$ROOT_DIR" . \
        | ssh "$external_host" "tar -xz -C '$remote_dir'"

    # The remote build.sh provisions its own build image from build-deps.txt,
    # so nothing needs to be preinstalled there beyond a container runtime.
    if [[ -z $(ssh "$external_host" "command -v podman || command -v docker") ]]; then
        fail "$external_host has no container runtime (podman/docker); install podman there"
    fi
    echo "==> Building on $external_host (log follows)..."
    ssh "$external_host" "cd '$remote_dir' && ${skip_env[*]+${skip_env[*]}} ./build.sh -H \
        -o '$remote_iso' -w '$remote_dir/work' -b '$remote_dir/.horizon-build' -l '$ISO_LABEL'"

    echo "==> Retrieving ISO images from $external_host..."
    mkdir -p "$ISO_OUT_DIR"
    # shellcheck disable=SC2029  # remote glob expansion is intended
    scp -q "$external_host:$remote_root/ISO/*.iso" "$ISO_OUT_DIR/"
    cd "$ISO_OUT_DIR" && sha256sum -- *.iso 2>/dev/null || true
    echo "==> External build complete; ISOs are in $ISO_OUT_DIR"
    exit 0
fi

# ------------------------------------------------------------------------------
# Container leg: provision the build environment ourselves, then re-enter
# this script inside it. Self-built tools below are compiled there too.
# ------------------------------------------------------------------------------
if (( ! host_mode )); then
    runtime=""
    for candidate in docker podman; do
        if command -v "$candidate" >/dev/null 2>&1; then runtime="$candidate"; break; fi
    done
    if [[ -z "$runtime" ]]; then
        fail "no container runtime (docker/podman) found; install one, or build on the host with -H"
    fi

    image_fingerprint="$(cat "$ROOT_DIR/Dockerfile" "$ROOT_DIR/build-deps.txt" \
        "$ROOT_DIR/tools/container/setup-build-env.sh" | sha256sum | cut -d' ' -f1)"
    state_file="$HORIZON_BUILD_DIR/container-image-fingerprint"
    mkdir -p "$HORIZON_BUILD_DIR"

    image_ok=0
    if "$runtime" image inspect "$IMAGE_TAG" >/dev/null 2>&1; then image_ok=1; fi
    if [[ "$no_cache" == 1 || ! -f "$state_file" \
          || "$(cat "$state_file" 2>/dev/null)" != "$image_fingerprint" \
          || "$image_ok" != 1 ]]; then
        echo "==> Provisioning build image (meson, ninja, cargo, archiso, ...) from build-deps.txt"
        "$runtime" build ${no_cache:+--no-cache} --tag "$IMAGE_TAG" --file "$ROOT_DIR/Dockerfile" "$ROOT_DIR" \
            || fail "image provisioning failed"
        printf '%s\n' "$image_fingerprint" > "$state_file"
    else
        echo "==> Build image up to date, skipping provisioning"
    fi

    # Mount only what lives outside the repo tree; everything else travels
    # with the repo bind mount. mkarchiso needs --privileged (loop devices,
    # chroot), matching CI's privileged container. :Z relabels on SELinux hosts.
    mounts=(-v "${ROOT_DIR}:/repo,Z")
    # Boot testing needs a virtualization accelerator; pass KVM through when
    # the host exposes it. Without it qemu falls back to TCG (slower).
    runtime_opts=(--rm --privileged)
    [[ -e /dev/kvm ]] && runtime_opts+=(--device /dev/kvm)
    if [[ "$ISO_OUT_DIR" != "$ROOT_DIR" && "$ISO_OUT_DIR" != "$ROOT_DIR"/* ]]; then
        mkdir -p "$ISO_OUT_DIR"
        mounts+=(-v "${ISO_OUT_DIR}:${ISO_OUT_DIR},Z")
    fi
    if [[ "$WORK_DIR" != "$ROOT_DIR" && "$WORK_DIR" != "$ROOT_DIR"/* ]]; then
        mkdir -p "$WORK_DIR"
        mounts+=(-v "${WORK_DIR}:${WORK_DIR},Z")
    fi

    echo "==> Running AcreetionOS Horizon build inside container..."
    pass_args=(-H)
    "$runtime" run \
        "${runtime_opts[@]}" \
        "${mounts[@]}" \
        ${rebuild_freeman:+-e HORIZON_REBUILD_FREEMAN=1} \
        -e "HORIZON_SKIP_PATCHED_PACKAGES=$skip_patched" \
        -e "HORIZON_SKIP_FREEMAN=$skip_freeman" \
        -e "HORIZON_SKIP_ISO=$skip_iso" \
        -e "HORIZON_SECURITY_GATE=$security_gate" \
        -e "HORIZON_BOOT_TEST=$boot_test" \
        -e "HORIZON_WITH_MULTILIB=$with_multilib" \
        -e "HORIZON_ARCH=$HORIZON_ARCH" \
        -e "HORIZON_BUILD_DIR=$HORIZON_BUILD_DIR" \
        -e "WORK_DIR=$WORK_DIR" -e "ISO_OUT_DIR=$ISO_OUT_DIR" \
        -e "ISO_LABEL=$ISO_LABEL" -e "PACMAN_CONF=$PACMAN_CONF" \
        -e "IMAGE_TAG=$IMAGE_TAG" \
        "$IMAGE_TAG" bash -lc '
            build_status=0
            ./build.sh "$@" || build_status=$?
            owner="$(stat -c %u:%g /repo)"
            chown -R "$owner" /repo/.horizon-build /repo/work "$ISO_OUT_DIR" 2>/dev/null || true
            exit $build_status
        ' bash "${pass_args[@]}"
    exit $?
fi

# ------------------------------------------------------------------------------
# Security gate: build tests + CVE comparison + private issue + auto-patch.
# Runs before every release-class build (i.e. the --alpha path and anything
# that asks for HORIZON_SECURITY_GATE=1).
# ------------------------------------------------------------------------------
if [[ "${HORIZON_SECURITY_GATE:-0}" == 1 ]]; then
    echo "==> Security gate (pre-release) starting..."
    "$ROOT_DIR/tools/security/security-gate.sh"
fi

# ------------------------------------------------------------------------------
# STEP 0: Build first-party tooling; prefer our own tools over stock ones.
#   - mkarchiso.c wrapper: recompiled whenever its source is newer, so the
#     ISO always goes through AcreetionOS' own build frontend.
#   - Freeman (step 2) and the patched-package builder are first-party already.
# ------------------------------------------------------------------------------
CFLAGS_WRAPPER="-Wall -Wextra -O2 -std=c11"
if [[ ! -x "$ROOT_DIR/mkarchiso" || "$ROOT_DIR/mkarchiso.c" -nt "$ROOT_DIR/mkarchiso" ]]; then
    echo "==> Step 0/3: Building first-party mkarchiso wrapper..."
    if ! command -v gcc >/dev/null 2>&1; then
        fail "gcc unavailable to build mkarchiso wrapper; use the packaged mkarchiso instead"
    fi
    gcc "$CFLAGS_WRAPPER" -o "$ROOT_DIR/mkarchiso" "$ROOT_DIR/mkarchiso.c"
    echo "    mkarchiso wrapper built."
fi
ISO_FRONTEND=("$ROOT_DIR/mkarchiso")
if [[ ! -x "$ROOT_DIR/mkarchiso" ]]; then
    echo "warning: ./mkarchiso unavailable; falling back to system mkarchiso" >&2
    ISO_FRONTEND=(mkarchiso)
fi

# ------------------------------------------------------------------------------
# STEP 1: Build patched GNOME 48 / XLibre packages if not explicitly skipped
# ------------------------------------------------------------------------------
if [[ "$skip_patched" != 1 ]]; then
    echo "==> Step 1/3: Building patched GNOME 48 & XLibre desktop components..."
    HORIZON_BUILD_DIR="$HORIZON_BUILD_DIR" \
        "$ROOT_DIR/xlibre-patches/build-patched-packages.sh"
else
    echo "==> Step 1/3: Skipping patched XLibre packages (HORIZON_SKIP_PATCHED_PACKAGES=$skip_patched)"
fi

# ------------------------------------------------------------------------------
# STEP 2: Build the Freeman update utility binary
# ------------------------------------------------------------------------------
if [[ "$skip_freeman" != 1 ]]; then
    mkdir -p "$HORIZON_BUILD_DIR"
    if [[ ! -x "$HORIZON_BUILD_DIR/freeman" || "$rebuild_freeman" == 1 ]]; then
        echo "==> Step 2/3: Building Freeman update utility..."
        # Compilation conversion (arch-layer): same-arch builds are plain;
        # cross builds carry the cargo target triple and linker from the layer
        # and land in the arch-specific target directory and slot.
        if [[ "$(uname -m)" == "$HORIZON_ARCH" ]]; then
            cargo build --release --manifest-path "$ROOT_DIR/tools/freeman/Cargo.toml"
            install -m 0755 "$ROOT_DIR/tools/freeman/target/release/pamac" "$HORIZON_BUILD_DIR/freeman-$HORIZON_ARCH"
        else
            cargo_build_args=$("$ROOT_DIR/tools/ci/arch-compile.sh" cargo "$HORIZON_ARCH")
            # shellcheck disable=SC2086
            cargo build --release \
                --manifest-path "$ROOT_DIR/tools/freeman/Cargo.toml" \
                $cargo_build_args
            install -m 0755 \
                "$ROOT_DIR/tools/freeman/target/$HORIZON_ARCH-unknown-linux-gnu/release/pamac" \
                "$HORIZON_BUILD_DIR/freeman-$HORIZON_ARCH"
        fi
        install -m 0755 "$HORIZON_BUILD_DIR/freeman-$HORIZON_ARCH" "$HORIZON_BUILD_DIR/freeman"
    fi
    mkdir -p "$ROOT_DIR/airootfs/usr/local/bin"
    install -m 0755 "$HORIZON_BUILD_DIR/freeman" "$ROOT_DIR/airootfs/usr/local/bin/freeman"
    echo "==> Step 2/3: Freeman installed to airootfs/usr/local/bin/freeman"
else
    echo "==> Step 2/3: Skipping Freeman (HORIZON_SKIP_FREEMAN=$skip_freeman)"
fi

# Ensure executable bits on custom airootfs scripts
chmod +x "$ROOT_DIR/airootfs/usr/local/bin/"* 2>/dev/null || true
chmod +x "$ROOT_DIR/airootfs/usr/bin/"* 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 3: Clean previous ISO artifacts & run mkarchiso (our wrapper)
# ------------------------------------------------------------------------------
if [[ "$skip_iso" == 1 ]]; then
    echo "==> Step 3/3: Skipping ISO construction (HORIZON_SKIP_ISO=$skip_iso)"
    exit 0
fi

echo "==> Step 3/3: Constructing final AcreetionOS Horizon ISO..."
mkdir -p "$ISO_OUT_DIR"
"$ROOT_DIR/refresh.sh" -j 2>/dev/null || rm -rf "$WORK_DIR" "$ROOT_DIR/out"

# Use patched pacman.conf from .horizon-build if present
EFFECTIVE_PACMAN_CONF="$PACMAN_CONF"
if [[ -f "$HORIZON_BUILD_DIR/pacman.conf" ]]; then
    EFFECTIVE_PACMAN_CONF="$HORIZON_BUILD_DIR/pacman.conf"
    echo "    Using layered pacman.conf with local patched repository"

    # mkarchiso's pacstrap runs with hostcache enabled, reusing the system's
    # /var/cache/pacman/pkg/ across builds. Our patched packages keep a
    # static pkgver/pkgrel/epoch between rebuilds, so a stale cached copy
    # from an earlier build can collide with the checksums repo-add just
    # wrote for this run's freshly compiled bytes. Evict only our own
    # packages so pacman is forced to pull the current build from the
    # local repo.
    if [[ -d "$HORIZON_BUILD_DIR/repo" ]]; then
        host_cache_dir="$(pacman-conf CacheDir 2>/dev/null | head -n1)"
        if [[ -n "$host_cache_dir" && -d "$host_cache_dir" ]]; then
            for pkg_file in "$HORIZON_BUILD_DIR/repo"/*.pkg.tar.*; do
                [[ -e "$pkg_file" ]] || continue
                rm -f "$host_cache_dir/$(basename "$pkg_file")"
            done
        fi
    fi
fi

export PACMAN_OPTS="--overwrite *"
export PACMAN_CONFIG="$EFFECTIVE_PACMAN_CONF"
"${ISO_FRONTEND[@]}" -L "$ISO_LABEL" -v -w "$WORK_DIR" -o "$ISO_OUT_DIR" -C "$EFFECTIVE_PACMAN_CONF" "$ROOT_DIR"

# ------------------------------------------------------------------------------
# Secondary build: same profile against the 32-bit (multilib) repositories.
# Yields *-Multilib ISOs next to the primary output for alpha QA.
# ------------------------------------------------------------------------------
if [[ "${HORIZON_WITH_MULTILIB:-0}" == 1 ]]; then
    if [[ "$HORIZON_ARCH" != "x86_64" ]]; then
        fail "multilib (32-bit repo) secondary builds only apply to x86_64; requested for arch: $HORIZON_ARCH"
    fi
    echo "==> Secondary build: multilib (32-bit repos) ISO..."
    multilib_conf="$HORIZON_BUILD_DIR/pacman.multilib.conf"
    # The secondary ISO's pacman.conf needs the FULL repo set (pacstrap reads
    # only -C), so start from the effective config and append the multilib
    # stanza rather than minting a fragment.
    cp -f -- "$EFFECTIVE_PACMAN_CONF" "$multilib_conf"
    if ! grep -qE '^(#?\[multilib\]|Include.*multilib)' "$multilib_conf"; then
        # $arch resolves to x86_64 for this secondary build (32-bit companion
        # libraries are only produced for the 64-bit target).
        printf '\n[multilib]\nSigLevel = Optional\nServer = https://geo.mirror.pkgbuild.com/multilib/os/x86_64\n' >> "$multilib_conf"
    fi
    echo "    multilib repository enabled in $multilib_conf"
    multilib_work="$ROOT_DIR/work-multilib"
    rm -rf "$multilib_work"
    "${ISO_FRONTEND[@]}" -L "${ISO_LABEL}-Multilib" -v -w "$multilib_work" \
        -o "$ISO_OUT_DIR" -C "$multilib_conf" "$ROOT_DIR"
    rm -rf "$multilib_work"
fi

# ------------------------------------------------------------------------------
# Boot-test matrix: the freshly built ISO(s) are booted in QEMU across every
# CPU generation (Intel/AMD) and hypervisor (kvm/tcg - xen when on a dom0).
# ------------------------------------------------------------------------------
if [[ "${HORIZON_BOOT_TEST:-0}" == 1 ]]; then
    echo "==> Boot-test matrix starting..."
    iso_count=1
    [[ "${HORIZON_WITH_MULTILIB:-0}" == 1 ]] && iso_count=2
    mapfile -t test_isos < <(ls -1t "$ISO_OUT_DIR"/*.iso | head -n "$iso_count")
    for test_iso in "${test_isos[@]}"; do
        echo "==> Boot-testing ISO: $test_iso"
        "$ROOT_DIR/tools/ci/boot-test.sh" --iso "$test_iso" || fail "boot-test FAILED for $test_iso"
    done
fi

echo "===================================================================="
echo "  AcreetionOS Horizon Build Complete!"
echo "  ISO Image located in: $ISO_OUT_DIR"
echo "===================================================================="
