#!/usr/bin/env bash
set -euo pipefail

export PACMAN_OPTS="--overwrite *"
./mkarchiso -L AcreetionOS_XL -v -o ../ISO -C ./pacman.conf .
