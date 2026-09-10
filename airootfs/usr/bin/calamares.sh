#!/usr/bin/env bash
set -euo pipefail

if [[ -f /mkinitcpio/mkinitcpio.conf ]]; then
    cp /mkinitcpio/mkinitcpio.conf /etc/mkinitcpio.conf
fi

exec /usr/bin/python3 /usr/local/lib/horizon-installer/installer.py
