# AcreetionOS Horizon Community Edition

AcreetionOS Horizon is the community desktop edition built around a maintained
GNOME 48 + XLibre X11 desktop stack. Wayland is deliberately not the target for Horizon.

## Why Horizon Exists

Modern upstream desktop releases are moving aggressively towards Wayland-only sessions.
Horizon retains the native X11 session by building against the GNOME 48 source release,
patched locally for full XLibre support and stability.

The core desktop packages are built locally at build-time using `./build-horizon-xlibre.sh`
which pulls sources, applies downstream patches from `xlibre-patches/`, compiles them, and
injects them into a local pacman repository for `mkarchiso` to consume.

## Why Pacman is Completely Removed

In an immutable, pinned desktop environment, running standard rolling upgrades
via `pacman -Syu` against live Arch Linux mirrors will break system compatibility.
It would replace the patched GNOME 48 / XLibre binaries with Wayland-only or
ABI-incompatible versions, rendering the desktop unable to start.

Therefore:
- `pacman` and its key management tools are completely removed from the installed OS.
- System updates are delivered as full, verified, atomic system images (similar to Android
  or SteamOS), rather than rolling file-by-file package swaps.

## Freeman & Image-Based Updates

Horizon ships with **Freeman** (`/usr/local/bin/freeman`), our customized package query and
image update tool. Freeman queries release metadata directly from GitLab/GitHub releases,
verifies cryptographic integrity, and stages updates locally:

```bash
# Check if a new verified system image is available
freeman checkupdates

# Download and verify the update image locally (SHA-256)
freeman update

# Apply the staged update to an inactive A/B root partition
freeman update --apply
```

First boot automatically displays an onboarding dialogue explaining Freeman and the
removal of pacman to ensure users understand how their system is maintained.

## Calamares Installer

Horizon bundles its custom Calamares configuration under `airootfs/etc/calamares/`,
customized for offline installation:
- Uses the `dummy` package operations module to avoid unwanted online network sync.
- Preconfigures GDM and X11 session defaults.
- Sets up the post-install scripts and autostart hooks.

## Applications via Arch Linux Distrobox & Graphical App Drawer

Since host pacman is removed to guarantee display stack immutability, application
packages and development dependencies can be installed safely inside an Arch Linux
Distrobox rootfs:

- **Launch from App Drawer**: All applications installed or exported from Distrobox appear
  automatically with an `[Arch App]` badge inside the graphical App Hub (`horizon-app-drawer`)
  and the main desktop application menu. Users simply click to launch without touching the CLI.
- **Search & Install via GUI**: The App Hub's "Get Applications" tab searches and provisions
  packages into the container and exports their desktop shortcuts in the background.
- **Terminal Access (Optional)**: Advanced users can run `horizon-apps` to open a shell inside
  the container with standard `pacman` and AUR tools.

## Graphical App Drawer & Software Hub (No CLI Required)

Users never need to touch the terminal to manage, launch, or install applications:
- **Horizon App Hub (`horizon-app-drawer`)**: A graphical application launcher, installer,
  and container application manager.
- **One-Click Launching**: Launches both host desktop software and isolated Arch Linux
  Distrobox applications directly from the interface.
- **Search & Install**: Automatically provisions new software inside the isolated Arch Linux
  Distrobox container and exports desktop shortcuts directly to the main desktop application menu.
- **Integrated Snapshots**: Trigger on-demand system backups or launch Timeshift directly
  from the UI.

## Data Protection & Timeshift Snapshots (ext4)

AcreetionOS Horizon relies on rock-solid **ext4** partitions for absolute stability:
- Automatic **Timeshift (rsync)** snapshot protection runs on boot and daily schedules.
- System root and persistent data are isolated so updates and app experiments cannot cause data loss.
- In the event of system corruption or bad configuration, Timeshift restores the root
  filesystem state immediately.

## Building the ISO (One-Command Build)

To build everything in one step (compiling patched XLibre desktop packages, building
the Freeman update tool, and constructing the bootable ISO):

```bash
./build.sh
```

Individual step scripts (`./build-horizon-xlibre.sh`, `./build-freeman.sh`) remain
available for isolated module development and CI pipelining.

## License

GPL-3.0. See `LICENSE` for details.
