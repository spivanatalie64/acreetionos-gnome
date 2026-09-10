#!/usr/bin/env bash
set -euo pipefail

name="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }')"
[[ -n "$name" ]] || exit 0
home="$(getent passwd "$name" | cut -d: -f6)"

install -d -o "$name" -g "$name" "$home/.config" "$home/.config/autostart"
[[ -f /etc/skel/.bashrc ]] && install -o "$name" -g "$name" /etc/skel/.bashrc "$home/.bashrc"
[[ -f /etc/skel/.nanorc ]] && install -o "$name" -g "$name" /etc/skel/.nanorc "$home/.nanorc"
[[ -f /middle.png ]] && install -o "$name" -g "$name" /middle.png "$home/middle.png"

# Setup onboarding welcome autostart for first user login
if [[ -f /etc/skel/.config/autostart/horizon-welcome.desktop ]]; then
    install -o "$name" -g "$name" /etc/skel/.config/autostart/horizon-welcome.desktop "$home/.config/autostart/horizon-welcome.desktop"
fi

if [[ -d /backgrounds ]]; then
    install -d /usr/share/backgrounds
    cp -a /backgrounds/. /usr/share/backgrounds/
    rm -rf /backgrounds
fi

[[ -f /etc/pacman2.conf ]] && cp /etc/pacman2.conf /etc/pacman.conf

if [[ -f /mkinitcpio/mkinitcpio.conf ]]; then
    cp /mkinitcpio/mkinitcpio.conf /etc/mkinitcpio.conf
    rm -rf /mkinitcpio
fi

# Remove pacman binaries from installed system to preserve XLibre/GNOME 48 immutability
rm -f /usr/bin/pacman /usr/bin/pacman-conf /usr/bin/pacman-key /usr/bin/pacman-db-upgrade

# Setup Timeshift and cronie services for automatic background ext4 snapshots
systemctl enable cronie.service || true

# Initialize baseline Timeshift snapshot if timeshift is available
if command -v timeshift &>/dev/null; then
    echo "Creating baseline initial Timeshift snapshot..."
    timeshift --create --comments "Initial post-installation baseline" || true
fi

rm -f /etc/mkinitcpio.conf.d/archiso.conf
systemctl enable gdm.service
systemctl daemon-reload
