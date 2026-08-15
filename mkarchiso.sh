#!/usr/bin/env bash
set -euo pipefail
# Output to ./ISO inside the repo — matches build.sh + CI artifact paths.
mkdir -p ./ISO
exec mkarchiso -L "acreetionOS_gnome_202608" -v -o ./ISO . -C ./pacman.conf
