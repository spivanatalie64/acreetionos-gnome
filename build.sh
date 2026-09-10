#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - Complete One-Command Unified Build Script
# ==============================================================================
#  Builds all required components in order:
#    1. Patched GNOME 48 + XLibre desktop stack (into .horizon-build/repo)
#    2. Freeman package & image update utility (into airootfs/usr/local/bin)
#    3. Clean workspace & construct final AcreetionOS Horizon ISO image
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HORIZON_BUILD_DIR="${HORIZON_BUILD_DIR:-$ROOT_DIR/.horizon-build}"
ISO_LABEL="${ISO_LABEL:-AcreetionOS-Horizon}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
ISO_OUT_DIR="${ISO_OUT_DIR:-$ROOT_DIR/../ISO}"
PACMAN_CONF="${PACMAN_CONF:-$ROOT_DIR/pacman.conf}"

echo "===================================================================="
echo "  Starting AcreetionOS Horizon Full Build"
echo "===================================================================="
echo "  Working directory: $ROOT_DIR"
echo "  Build directory:   $HORIZON_BUILD_DIR"
echo "  ISO Output:        $ISO_OUT_DIR"
echo "===================================================================="

# ------------------------------------------------------------------------------
# STEP 1: Build patched GNOME 48 / XLibre packages if not explicitly skipped
# ------------------------------------------------------------------------------
if [[ "${HORIZON_SKIP_PATCHED_PACKAGES:-0}" != 1 ]]; then
    echo "==> Step 1/3: Building patched GNOME 48 & XLibre desktop components..."
    if [[ -x "$ROOT_DIR/xlibre-patches/build-patched-packages.sh" ]]; then
        HORIZON_BUILD_DIR="$HORIZON_BUILD_DIR" "$ROOT_DIR/xlibre-patches/build-patched-packages.sh"
    elif [[ -x "$ROOT_DIR/build-horizon-xlibre.sh" ]]; then
        HORIZON_BUILD_DIR="$HORIZON_BUILD_DIR" "$ROOT_DIR/build-horizon-xlibre.sh"
    fi
else
    echo "==> Step 1/3: Skipping patched XLibre packages (HORIZON_SKIP_PATCHED_PACKAGES=1)"
fi

# ------------------------------------------------------------------------------
# STEP 2: Build the Freeman update utility binary
# ------------------------------------------------------------------------------
echo "==> Step 2/3: Building Freeman update utility..."
mkdir -p "$HORIZON_BUILD_DIR"
if [[ -f "$ROOT_DIR/tools/freeman/Cargo.toml" ]]; then
    if [[ ! -x "$HORIZON_BUILD_DIR/freeman" || "${HORIZON_REBUILD_FREEMAN:-1}" == 1 ]]; then
        cargo build --release --manifest-path "$ROOT_DIR/tools/freeman/Cargo.toml"
        install -m 0755 "$ROOT_DIR/tools/freeman/target/release/pamac" "$HORIZON_BUILD_DIR/freeman"
    fi
fi

if [[ -f "$HORIZON_BUILD_DIR/freeman" ]]; then
    mkdir -p "$ROOT_DIR/airootfs/usr/local/bin"
    install -m 0755 "$HORIZON_BUILD_DIR/freeman" "$ROOT_DIR/airootfs/usr/local/bin/freeman"
    echo "    Freeman installed to airootfs/usr/local/bin/freeman"
fi

# Ensure executable bits on custom airootfs scripts
chmod +x "$ROOT_DIR/airootfs/usr/local/bin/"* 2>/dev/null || true
chmod +x "$ROOT_DIR/airootfs/usr/bin/"* 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 3: Clean previous ISO artifacts & run mkarchiso
# ------------------------------------------------------------------------------
echo "==> Step 3/3: Constructing final AcreetionOS Horizon ISO..."
mkdir -p "$ISO_OUT_DIR"
"$ROOT_DIR/refresh.sh" -j 2>/dev/null || rm -rf "$WORK_DIR" "$ROOT_DIR/out"

# Use patched pacman.conf from .horizon-build if present
EFFECTIVE_PACMAN_CONF="$PACMAN_CONF"
if [[ -f "$HORIZON_BUILD_DIR/pacman.conf" ]]; then
    EFFECTIVE_PACMAN_CONF="$HORIZON_BUILD_DIR/pacman.conf"
    echo "    Using layered pacman.conf with local patched repository"
fi

export PACMAN_OPTS="--overwrite *"
export PACMAN_CONFIG="$EFFECTIVE_PACMAN_CONF"
mkarchiso \
    -L "$ISO_LABEL" \
    -v \
    -w "$WORK_DIR" \
    -o "$ISO_OUT_DIR" \
    -C "$EFFECTIVE_PACMAN_CONF" \
    "$ROOT_DIR"

echo "===================================================================="
echo "  AcreetionOS Horizon Build Complete!"
echo "  ISO Image located in: $ISO_OUT_DIR"
echo "===================================================================="
