#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - container build-environment bootstrap
# ==============================================================================
#  Runs inside the container image (Dockerfile RUN step) and provisiones
#  everything the full build needs: pacman keyring, the acreetionOS package
#  repository, and the toolchain listed in build-deps.txt. Keeps the container
#  self-configuring so the image never goes stale against a changed
#  build-deps.txt.
# ==============================================================================
set -euo pipefail

deps_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/build-deps.txt"
[[ -f "$deps_file" ]] || { printf 'error: missing dependency manifest: %s\n' "$deps_file" >&2; exit 1; }

mapfile -t packages < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$deps_file")
(( ${#packages[@]} > 0 )) || { printf 'error: dependency manifest is empty: %s\n' "$deps_file" >&2; exit 1; }

echo '==> Initialising pacman keyring...'
pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm --needed archlinux-keyring ccache

echo '==> Adding acreetionOS custom repository...'
printf '\n[acreetionOSREPO]\nSigLevel = Optional\nServer = https://iso.acreetionos.org:8448/repo/$arch\n' >> /etc/pacman.conf
pacman -Sy

echo '==> Installing build tools and build dependencies...'
pacman -S --noconfirm --needed "${packages[@]}"

echo '==> Build environment ready.'
