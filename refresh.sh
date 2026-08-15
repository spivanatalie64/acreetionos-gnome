#!/usr/bin/env bash
# refresh.sh — Clean build artifacts
set -e
for arg in "$@"; do
  case "$arg" in
    -j|-j1|-j2|-j4|-j8|-j16) : ;;
  esac
done
echo "  :: Removing work/, out/ and ISO/..."
rm -rf ./work ./out ./ISO
echo "  :: Clean!"
