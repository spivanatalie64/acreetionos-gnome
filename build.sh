#!/usr/bin/env bash
# build.sh — Build AcreetionOS-GNOME ISO
# Usage: ./build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/../ISO}"

cd "$SCRIPT_DIR"

echo "  :: AcreetionOS-GNOME — Building ISO"
echo "  :: Output: ${OUTPUT_DIR}"

if [ -f ./generate-build-info.sh ]; then
  ./generate-build-info.sh
fi

echo "  :: Cleaning workspace..."
./refresh.sh -j 2>/dev/null || true

echo "  :: Running mkarchiso..."
./mkarchiso.sh

FOUND_ISO=$(find "${OUTPUT_DIR}" -name "AcreetionOS-GNOME*.iso" -type f 2>/dev/null | head -1)
if [ -n "$FOUND_ISO" ]; then
  echo "  ✓ ISO: $FOUND_ISO"
  ls -lh "$FOUND_ISO" 2>/dev/null || true
else
  echo "  ! No ISO found in ${OUTPUT_DIR}/ — checking out/"
  ls -lh out/ 2>/dev/null || true
fi

# NOTE: no  here — deleting a multi-GB tree inside the CI
# container can OOM-kill the build script itself (seen in practice). The
# .gitignore covers local builds; CI containers are ephemeral anyway.
echo "  :: Done!"
