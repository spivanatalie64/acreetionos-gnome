# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AcreetionOS Horizon is an Arch Linux-based community edition targeting x86_64 architecture,
delivering a native X11 GNOME 48 desktop powered by XLibre, completely replacing pacman
with the Freeman update utility for Android/SteamOS-style image updates.

## Build Commands

### Primary Build Process
- **Full One-Command Build**: `./build.sh` - Builds XLibre stack, Freeman, and the Horizon ISO
- **Sub-step 1: Build patched XLibre desktop stack**: `./build-horizon-xlibre.sh`
- **Sub-step 2: Build Freeman utility**: `./build-freeman.sh`
- **Clean workspace**: `./refresh.sh` - Removes work/ and out/ directories

## Architecture

### Key Configuration Files
- **profiledef.sh**: Main archiso profile configuration defining ISO metadata and file permissions
- **packages.x86_64**: Complete package list for the distribution
- **pacman.conf**: Custom Pacman configuration for building the ISO
- **airootfs/etc/calamares/**: Bundled offline Calamares installer configuration

### Directory Structure
- **airootfs/**: Root filesystem overlay that becomes the live system
  - `etc/calamares/`: Calamares installer configuration
  - `usr/local/bin/freeman`: Freeman package query & image update utility
  - `usr/local/bin/horizon-firstboot.sh`: Onboarding dialog explaining pacman removal & Freeman
  - `usr/local/bin/horizon-image-update`: Backend image update downloader/verifier/writer
- **xlibre-patches/**: Pinned source configurations and patches for GNOME 48 / XLibre
- **tools/freeman/**: Rust source for the Freeman CLI
- **grub/**, **syslinux/**, **efiboot/**: Bootloader configurations
