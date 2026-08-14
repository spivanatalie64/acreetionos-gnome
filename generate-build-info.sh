#!/bin/bash
# generate-build-info.sh — Write build metadata to airootfs

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date)
GIT_USER=$(git config user.name 2>/dev/null || echo "builder")

BUILD_INFO="Commit: $GIT_COMMIT
Date: $BUILD_DATE
User: $GIT_USER"

echo "$BUILD_INFO" > airootfs/etc/acreetion-build
echo "  :: Build info written to airootfs/etc/acreetion-build"
