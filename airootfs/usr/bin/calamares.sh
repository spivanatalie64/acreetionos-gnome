#!/bin/bash
# Launch the Calamares system installer with live-environment fixes applied
cp /mkinitcpio/mkinitcpio.conf /etc/mkinitcpio.conf
sudo pacman-key --init
sudo pacman -Syy
sudo pacman -S pacman --noconfirm --overwrite '*'
sudo pacman -S calamares-config --noconfirm --overwrite '*'
exec calamares -d8 > /root/calamares.log 2>&1
