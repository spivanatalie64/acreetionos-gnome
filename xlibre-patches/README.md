# Horizon XLibre Build

The XLibre build fetches pinned GNOME 48 sources from the official GitHub
mirrors, applies package-specific patches from this directory, builds local
packages, and creates a temporary pacman repository for the ISO.

Package patches belong in `xlibre-patches/<package-name>/*.patch`.
