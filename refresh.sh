#!/usr/bin/env bash
# refresh.sh — Clean build artifacts
set -e
for arg in "$@"; do
  case "$arg" in
    -j|-j1|-j2|-j4|-j8|-j16)
      # ignore -j flags for compatibility
      ;;
  esac
done
echo "  :: Removing work/ and out/..."
rm -rf ./work ./out
echo "  :: Clean!"
