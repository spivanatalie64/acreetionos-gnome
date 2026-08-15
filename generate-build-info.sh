#!/usr/bin/env bash
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date)
echo -e "Commit: $GIT_COMMIT\nDate: $BUILD_DATE" > airootfs/etc/acreetion-build 2>/dev/null || true
