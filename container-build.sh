#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - self-contained container build entry point
# ==============================================================================
#  Purpose: the build must never depend on how the host was provisioned.
#  This wrapper provisions the build environment itself inside a container
#  (see Dockerfile) and runs ./build.sh in it, so a host only needs git,
#  bash, and a container runtime (Docker or Podman).
#
#  Usage:   ./container-build.sh
#  Env:     HORIZON_CONTAINER_RUNTIME   force docker|podman
#           HORIZON_CONTAINER_IMAGE     image tag (default: horizon-build:latest)
#           HORIZON_NO_IMAGE_CACHE      rebuild the image from scratch
#           HORIZON_* / WORK_DIR / ISO_OUT_DIR / ISO_LABEL / PACMAN_CONF
#                                       forwarded to build.sh
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${HORIZON_CONTAINER_IMAGE:-horizon-build:latest}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
ISO_OUT_DIR="${ISO_OUT_DIR:-$ROOT_DIR/../ISO}"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 1. Pick a container runtime
# ------------------------------------------------------------------------------
runtime="${HORIZON_CONTAINER_RUNTIME:-}"
if [[ -z "$runtime" ]]; then
    for candidate in docker podman; do
        if command -v "$candidate" >/dev/null 2>&1; then runtime="$candidate"; break; fi
    done
fi
command -v "$runtime" >/dev/null 2>&1 || fail "no container runtime found (tried docker, podman); install one or set HORIZON_CONTAINER_RUNTIME"
echo "==> Using container runtime: $runtime"

# ------------------------------------------------------------------------------
# 2. Build the image when missing or when its inputs changed
# ------------------------------------------------------------------------------
image_fingerprint="$(cat "$ROOT_DIR/Dockerfile" "$ROOT_DIR/build-deps.txt" "$ROOT_DIR/tools/container/setup-build-env.sh" 2>/dev/null | sha256sum | cut -d' ' -f1)"
state_file="$ROOT_DIR/.horizon-build/container-image-fingerprint"

if [[ "${HORIZON_NO_IMAGE_CACHE:-0}" == 1 ]] || \
   [[ ! -f "$state_file" || "$(cat "$state_file" 2>/dev/null)" != "$image_fingerprint" ]] || \
   ! "$runtime" image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "==> Provisioning build image (installs meson, ninja, cargo, archiso, ...)"
    "$runtime" build \
        ${HORIZON_NO_IMAGE_CACHE:+--no-cache} \
        --tag "$IMAGE_TAG" \
        --file "$ROOT_DIR/Dockerfile" \
        "$ROOT_DIR"
    mkdir -p "$ROOT_DIR/.horizon-build"
    printf '%s\n' "$image_fingerprint" > "$state_file"
else
    echo "==> Build image up to date, skipping provisioning"
fi

# ------------------------------------------------------------------------------
# 3. Run the full build inside the container
# ------------------------------------------------------------------------------
mkdir -p "$WORK_DIR" "$ISO_OUT_DIR"

# mkarchiso needs loop devices and chroot/mount privileges, matching CI's
# `--privileged` container option (see .github/workflows/build-iso.yml).
# The :Z suffix relabels bind mounts on SELinux hosts (Podman/Docker).
# Package downloads are cached in a named volume so rebuilds stay fast.
mount_flags=",Z"
extra_mounts=()
[[ "$WORK_DIR" != "$ROOT_DIR" && "$WORK_DIR" != "$ROOT_DIR"/* ]] && \
    extra_mounts+=(-v "${WORK_DIR}:${WORK_DIR}${mount_flags}")

echo "==> Running AcreetionOS Horizon build inside container..."
# shellcheck disable=SC2086
"$runtime" run \
    --rm \
    --privileged \
    -v "${ROOT_DIR}:/repo${mount_flags}" \
    -v "${ISO_OUT_DIR}:/iso-out${mount_flags}" \
    ${extra_mounts[@]+"${extra_mounts[@]}"} \
    -e "ISO_OUT_DIR=/iso-out" \
    -e "WORK_DIR=/repo/work" \
    "$IMAGE_TAG" \
    bash -euo pipefail -c '
        build_status=0
        ./build.sh || build_status=$?
        # Return bind-mounted outputs to the host user.
        owner="$(stat -c %u:%g /repo)"
        chown -R "$owner" /repo/.horizon-build /repo/work /iso-out 2>/dev/null || true
        exit $build_status
    '
