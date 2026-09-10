#!/bin/bash
# Human-readable source for the base64 blob embedded in
# shellprocess-bootfix.conf. This file is NOT executed by Calamares and is
# NOT installed onto the target system - it exists purely so the actual
# fix is reviewable/maintainable without decoding base64 by hand.
#
# WHY BASE64: Calamares expands ${ROOT}/${USER}/etc.-style variables in
# every "command:" string before handing it to the shell (see
# CommandList::run() -> KWordMacroExpander in Calamares' source). This pass
# is not shell-quote-aware, so any bare $word or ${word} anywhere in the
# script text - even inside single quotes - is treated as an unresolved
# Calamares macro and hard-fails the whole job with "Missing variables"
# before the shell ever runs. Base64 has no "$" in its alphabet, so
# encoding this script sidesteps that pass entirely; it's decoded and run
# at actual execution time.
#
# To regenerate the blob after editing this file:
#   base64 -w0 shellprocess-bootfix.source.sh
# then paste the output into shellprocess-bootfix.conf as:
#   command: "-echo <blob> | base64 -d | bash"

{
    # The live ISO forces volatile (RAM-only) journald storage so it never
    # writes to the read-only squashfs. That drop-in gets carried onto the
    # installed system too, which means any boot failure - like a GPU
    # losing signal before a login is ever reached - leaves zero forensic
    # trail. Remove it so the installed system logs persist across boots.
    rm -f /etc/systemd/journald.conf.d/volatile-storage.conf
    mkdir -p /var/log/journal
    chgrp systemd-journal /var/log/journal 2>/dev/null
    chmod 2755 /var/log/journal 2>/dev/null

    # mkinitcpio's autodetect/kms hooks can't see real GPU hardware while
    # running inside the install chroot, so nvidia's early-KMS modules
    # never make it into the initramfs and nouveau is free to race the
    # nvidia driver for the display at boot. Only touch nvidia/nouveau
    # config if the user actually selected an nvidia driver group.
    if pacman -Qq nvidia-open-dkms &>/dev/null || pacman -Qq nvidia-dkms &>/dev/null || pacman -Qq nvidia &>/dev/null; then
        mkdir -p /etc/modprobe.d
        if ! grep -rq '^blacklist nouveau' /etc/modprobe.d/ 2>/dev/null; then
            printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
        fi
        if grep -q '^MODULES=(' /etc/mkinitcpio.conf 2>/dev/null && ! grep -q 'nvidia_drm' /etc/mkinitcpio.conf; then
            sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_drm nvidia_uvm /' /etc/mkinitcpio.conf
        fi

        # Even with early KMS working, Xorg auto-probes every DRM device it
        # can find and tries to configure each as its own screen with a
        # generic fallback driver (modesetting/nouveau/etc.) - including the
        # leftover simpledrm/EFI-framebuffer device the kernel always
        # registers on UEFI systems. That second screen tries to grab DRM
        # master on hardware nvidia already owns, fails with "Device or
        # resource busy", and because Xorg treats any screen init failure as
        # fatal, the whole server dies (total signal loss, well after
        # plymouth's own KMS use already succeeded).
        #
        # Option "AutoAddGPU" "false" does NOT stop this on this XLibre
        # build - confirmed via Xorg.0.log, it's read correctly ("(**)
        # Option AutoAddGPU false") but Xorg still enumerates and configures
        # the second screen anyway. What actually works is bypassing
        # autoconfig entirely with an explicit Device/Screen/ServerLayout
        # pinned to the nvidia PCI device, detected here from sysfs rather
        # than hardcoded, since the bus address varies per machine.
        rm -f /etc/X11/xorg.conf.d/99-nvidia-no-autoaddgpu.conf
        NVIDIA_BUSID=""
        for dev in /sys/bus/pci/devices/*/; do
            vendor=$(cat "${dev}vendor" 2>/dev/null)
            class=$(cat "${dev}class" 2>/dev/null)
            if [ "$vendor" = "0x10de" ] && { [ "${class:2:4}" = "0300" ] || [ "${class:2:4}" = "0302" ]; }; then
                pciaddr=$(basename "$dev")
                rest="${pciaddr#*:}"
                bus_hex="${rest%%:*}"
                rest2="${rest#*:}"
                dev_hex="${rest2%%.*}"
                func_hex="${rest2##*.}"
                NVIDIA_BUSID="PCI:$((16#$bus_hex)):$((16#$dev_hex)):$((16#$func_hex))"
                break
            fi
        done

        if [ -n "$NVIDIA_BUSID" ]; then
            mkdir -p /etc/X11/xorg.conf.d
            {
                echo 'Section "Device"'
                echo '    Identifier "nvidia"'
                echo '    Driver "nvidia"'
                echo "    BusID \"${NVIDIA_BUSID}\""
                echo 'EndSection'
                echo ''
                echo 'Section "Screen"'
                echo '    Identifier "Screen0"'
                echo '    Device "nvidia"'
                echo 'EndSection'
                echo ''
                echo 'Section "ServerLayout"'
                echo '    Identifier "layout"'
                echo '    Screen 0 "Screen0"'
                echo 'EndSection'
            } > /etc/X11/xorg.conf.d/10-nvidia-pin.conf
        fi
    fi

    # The live ISO's linux.preset is built for the archiso live-boot
    # environment. If it's still in that form on the installed system,
    # replace it with a normal preset before regenerating images.
    for preset in /etc/mkinitcpio.d/*.preset; do
        [ -f "$preset" ] || continue
        if grep -q "PRESETS=('archiso')" "$preset" 2>/dev/null; then
            kver=$(basename "$preset" .preset)
            {
                echo "ALL_kver=\"/boot/vmlinuz-${kver}\""
                echo "PRESETS=('default')"
                echo "default_image=\"/boot/initramfs-${kver}.img\""
            } > "$preset"
        fi
    done

    mkinitcpio -P
} > /var/log/calamares-bootfix.log 2>&1
exit 0
