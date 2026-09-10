#!/usr/bin/env bash
set -euo pipefail

./xlibre-patches/build-patched-packages.sh
./build-freeman.sh
