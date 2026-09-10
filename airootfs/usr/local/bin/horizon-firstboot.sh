#!/usr/bin/env bash
set -euo pipefail

MARKER="$HOME/.config/horizon/.onboarded"
mkdir -p "$HOME/.config/horizon"

if [[ -f "$MARKER" ]]; then
    exit 0
fi

TITLE="Welcome to AcreetionOS Horizon"
MSG="Welcome to AcreetionOS Horizon Community Edition!\n\n\
Key things to know about your system:\n\n\
1. Standard 'pacman' is completely removed.\n\
   Arch-style rolling package upgrades would overwrite the pinned GNOME 48\n\
   and custom XLibre compatibility layer, causing system breakage.\n\n\
2. Freeman & Image-Based Updates:\n\
   AcreetionOS Horizon uses Freeman for package queries and Android/SteamOS-style\n\
   atomic image updates directly from GitLab/GitHub releases.\n\n\
   - Check updates:   freeman checkupdates\n\
   - Download update: freeman update\n\
   - Apply update:    freeman update --apply\n\n\
3. Arch Linux Apps via Distrobox:\n\
   Need pacman, AUR packages, or standard CLI/GUI apps without risking\n\
   host desktop stability? Run 'horizon-apps' to enter your dedicated\n\
   Arch Linux container with full pacman/AUR access.\n\n\
4. Flatpak & Standalone Software:\n\
   Flatpak is pre-configured for desktop apps.\n\n\
Enjoy your clean, native X11 GNOME experience!"

if command -v zenity &>/dev/null; then
    zenity --info --title="$TITLE" --text="$MSG" --width=520 --height=380 || true
elif command -v notify-send &>/dev/null; then
    notify-send "$TITLE" "Welcome to Horizon! Pacman has been replaced by Freeman for image-based updates."
fi

touch "$MARKER"
