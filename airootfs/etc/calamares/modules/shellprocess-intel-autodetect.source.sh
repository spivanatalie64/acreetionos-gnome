#!/bin/bash
# Human-readable source for the base64 blob embedded in
# shellprocess-intel-autodetect.conf. This file is NOT executed by
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
#   base64 -w0 shellprocess-intel-autodetect.source.sh
# then paste the output into shellprocess-intel-autodetect.conf as:
#   command: "-echo <blob> | base64 -d | bash"
#
# WHY THIS EXISTS: same rationale as the nvidia autodetect step - relying
# on the user to notice and tick "Intel Graphics Drivers" on the drivers
# page is what causes installs stuck on unaccelerated/software rendering.
# i915 itself is already in-kernel and loads unprompted, but the userspace
# half (mesa/vulkan-intel/media driver) only gets installed if the
# checkbox was ticked. Detect the GPU directly from PCI (sysfs) instead of
# trusting a checkbox, and install the standard driver set whenever Intel
# graphics hardware is present, regardless of what was (or wasn't)
# selected on the drivers page.
{
    INTEL_FOUND=0
    for dev in /sys/bus/pci/devices/*/; do
        vendor=$(cat "${dev}vendor" 2>/dev/null)
        class=$(cat "${dev}class" 2>/dev/null)
        # 0x8086 = Intel. Class 0300 = VGA controller, 0302 = 3D controller
        # (covers secondary/muxless GPUs on hybrid laptops too).
        if [ "$vendor" = "0x8086" ] && { [ "${class:2:4}" = "0300" ] || [ "${class:2:4}" = "0302" ]; }; then
            INTEL_FOUND=1
            break
        fi
    done

    # If the user already picked the Intel group on the drivers page,
    # pacman will just no-op on the --needed install below - but skip the
    # sync/install entirely in that case to save time.
    if [ "$INTEL_FOUND" = "1" ] && ! pacman -Qq vulkan-intel &>/dev/null; then
        pacman -Sy --needed --noconfirm intel-media-driver intel-media-sdk lib32-mesa vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader
    fi
} > /var/log/calamares-intel-autodetect.log 2>&1
exit 0
