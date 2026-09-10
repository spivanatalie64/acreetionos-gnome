#!/bin/bash
# Human-readable source for the base64 blob embedded in
# shellprocess-amd-autodetect.conf. This file is NOT executed by
# Calamares and is NOT installed onto the target system - it exists purely
# so the actual fix is reviewable/maintainable without decoding base64 by
# hand.
#
# WHY BASE64: see shellprocess-bootfix.source.sh in this directory for the
# full explanation of Calamares' variable-expansion pass (KWordMacroExpander
# in CommandList::run()). Same issue applies here since this script uses
# bare $ shell variables.
#
# To regenerate the blob after editing this file:
#   base64 -w0 shellprocess-amd-autodetect.source.sh
# then paste the output into shellprocess-amd-autodetect.conf as:
#   command: "-echo <blob> | base64 -d | bash"
#
# WHY THIS EXISTS: same rationale as the nvidia autodetect step - relying
# on the user to notice and tick "AMD Graphics Drivers" on the drivers
# page is what causes installs stuck on unaccelerated/software rendering.
# amdgpu itself is already in-kernel and loads unprompted, but the
# userspace half (mesa/vulkan-radeon) only gets installed if the checkbox
# was ticked. Detect the GPU directly from PCI (sysfs) instead of trusting
# a checkbox, and install the standard driver set whenever AMD hardware is
# present, regardless of what was (or wasn't) selected on the drivers page.
{
    AMD_FOUND=0
    for dev in /sys/bus/pci/devices/*/; do
        vendor=$(cat "${dev}vendor" 2>/dev/null)
        class=$(cat "${dev}class" 2>/dev/null)
        # 0x1002 = AMD/ATI. Class 0300 = VGA controller, 0302 = 3D controller
        # (covers secondary/muxless GPUs on hybrid laptops too).
        if [ "$vendor" = "0x1002" ] && { [ "${class:2:4}" = "0300" ] || [ "${class:2:4}" = "0302" ]; }; then
            AMD_FOUND=1
            break
        fi
    done

    # If the user already picked the AMD group on the drivers page, pacman
    # will just no-op on the --needed install below - but skip the
    # sync/install entirely in that case to save time.
    if [ "$AMD_FOUND" = "1" ] && ! pacman -Qq vulkan-radeon &>/dev/null; then
        pacman -Sy --needed --noconfirm lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader
    fi
} > /var/log/calamares-amd-autodetect.log 2>&1
exit 0
