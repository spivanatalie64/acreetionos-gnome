#!/usr/bin/env bash
# build.sh — Build AcreetionOS-GNOME ISO
# NOTE: deliberately no 'set -e' — mkarchiso can exit non-zero after a valid ISO.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/ISO}"
cd "$SCRIPT_DIR" || exit 1
echo "  :: AcreetionOS-GNOME — Building ISO"
echo "  :: Output: ${OUTPUT_DIR}"
if [ -f ./generate-build-info.sh ]; then ./generate-build-info.sh; fi
echo "  :: Cleaning workspace..."
./refresh.sh -j 2>/dev/null || true
echo "  :: Running mkarchiso..."
mkdir -p "${OUTPUT_DIR}"
./mkarchiso.sh || true
FOUND_ISO=$(find "${OUTPUT_DIR}" -name "AcreetionOS-GNOME*.iso" -type f 2>/dev/null | head -1 || true)
if [ -n "$FOUND_ISO" ]; then
  echo "  ✓ ISO: $FOUND_ISO"
  ls -lh "$FOUND_ISO" 2>/dev/null || true
else
  echo "  ! No ISO found in ${OUTPUT_DIR} — checking out/"
  ls -lh out/ 2>/dev/null || true
fi
echo "  :: Done!"
