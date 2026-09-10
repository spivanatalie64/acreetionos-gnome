#!/bin/bash
# Human-readable source for the base64 blob embedded in
# shellprocess-nvidia-autodetect.conf. This file is NOT executed by
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
#   base64 -w0 shellprocess-nvidia-autodetect.source.sh
# then paste the output into shellprocess-nvidia-autodetect.conf as:
#   command: "-echo <blob> | base64 -d | bash"
#
# WHY THIS EXISTS: relying on the user to notice and tick the "Nvidia"
# checkbox on the drivers page is exactly what causes broken installs.
# Detect the GPU directly from PCI (sysfs) instead of trusting a checkbox,
# then install the driver set that actually matches the card - regardless
# of what was (or wasn't) selected on the drivers page.
#
# WHY THE GENERATION GATE: current NVIDIA drivers only support Pascal
# (GeForce GTX 10xx, 2016) and newer. Older cards - Maxwell (GTX 9xx),
# Kepler, Fermi - were moved to the 470xx / 390xx legacy branches, which
# are not in the Arch repos. Installing a current driver on those cards
# leaves the user with a black screen, so for pre-Pascal hardware we
# deliberately do nothing and let nouveau drive the display.
#
#   Turing (RTX 20xx / GTX 16xx) and newer -> nvidia-open-dkms
#     (NVIDIA's open kernel modules: required for Turing+ GSP and now the
#      recommended default.)
#   Pascal (GTX 10xx) and Volta            -> nvidia-dkms
#     (proprietary: nvidia-open does NOT support pre-Turing hardware, so
#      installing nvidia-open here would itself be a broken-driver bug.)
#   Maxwell (GTX 9xx), Kepler, Fermi, older -> nothing (keep nouveau).
{
    # --- 1. Is there an NVIDIA display GPU on the PCI bus? ---
    NVIDIA_FOUND=0
    NVIDIA_SLOT=""
    for dev in /sys/bus/pci/devices/*/; do
        vendor=$(cat "${dev}vendor" 2>/dev/null)
        class=$(cat "${dev}class" 2>/dev/null)
        # 0x10de = NVIDIA. Class 0300 = VGA controller, 0302 = 3D controller
        # (covers secondary/muxless GPUs on hybrid laptops too).
        if [ "$vendor" = "0x10de" ] && { [ "${class:2:4}" = "0300" ] || [ "${class:2:4}" = "0302" ]; }; then
            NVIDIA_FOUND=1
            NVIDIA_SLOT=$(basename "$dev")
            break
        fi
    done

    if [ "$NVIDIA_FOUND" != "1" ]; then
        echo "No NVIDIA display GPU on the PCI bus - nothing to do."
        exit 0
    fi

    # --- 2. Did the user already pick an nvidia group on the drivers page? ---
    if pacman -Qq nvidia-open-dkms &>/dev/null || pacman -Qq nvidia-dkms &>/dev/null || pacman -Qq nvidia &>/dev/null; then
        echo "An nvidia driver package is already installed - leaving it alone."
        exit 0
    fi

    # --- 3. Work out the GPU architecture ---
    # The chip codename in the PCI device string (GP104, TU116, AD107, ...)
    # is the most reliable signal. Fall back to nouveau's dmesg line, then
    # to the marketing name, for when the ISO's pci.ids is too old to name
    # a brand-new card.
    DESC=$(lspci -nn -s "$NVIDIA_SLOT" 2>/dev/null | sed 's/^[^:]*: //')
    [ -z "$DESC" ] && DESC=$(lspci -nn 2>/dev/null | grep -Ei '\[030[02]\].*\[10de:' | head -n1 | sed 's/^[^:]*: //')

    CODENAME=$(printf '%s\n' "$DESC" | grep -oE '\b(NV[0-9]+|[A-Z]{1,2}[0-9]{2,3}[A-Za-z]?)\b' | head -n1)
    [ -z "$CODENAME" ] && CODENAME=$(dmesg 2>/dev/null | grep -oE 'NVIDIA [A-Z]{2}[0-9]{2,3}[A-Za-z]?' | head -n1 | awk '{print $2}')

    ARCH="unknown"
    case "$CODENAME" in
        TU*|GA*|AD*|GB*|GH*)                            ARCH="turing_plus" ;;
        GP*|GV*)                                        ARCH="pascal_volta" ;;
        GM*|GK*|GF*|GT[0-9]*|G[0-9]*|NV*|MCP*|C[0-9]*)  ARCH="legacy" ;;
    esac

    if [ "$ARCH" = "unknown" ]; then
        case "$DESC" in
            *RTX*|*"GTX 16"*)
                ARCH="turing_plus" ;;
            *"GTX 10"*|*"TITAN Xp"*|*"TITAN X (Pascal)"*)
                ARCH="pascal_volta" ;;
            *"GTX 9"*|*"GTX 8"*|*"GTX 7"*|*"GTX 6"*|*"GTX 5"*|*"GTX 4"*|*"GT 7"*|*"GT 6"*|*"GT 5"*|*"GT 4"*|*"GT 3"*|*"GeForce 9"*|*"GeForce 8"*|*"GeForce 7"*)
                ARCH="legacy" ;;
        esac
    fi

    echo "Detected GPU: ${DESC:-unknown} (codename: ${CODENAME:-unknown}, arch: $ARCH)"

    # --- 4. Install (or deliberately don't) ---
    case "$ARCH" in
        turing_plus)
            echo "Turing or newer -> installing nvidia-open-dkms"
            pacman -Sy --needed --noconfirm nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils
            ;;
        pascal_volta)
            echo "Pascal/Volta -> installing proprietary nvidia-dkms"
            pacman -Sy --needed --noconfirm nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils
            ;;
        legacy)
            echo "Pre-Pascal (Maxwell/Kepler/Fermi/older): current NVIDIA drivers"
            echo "have dropped support and the legacy branches are not in the Arch"
            echo "repos. Leaving nouveau in place - installing a current driver"
            echo "here would break the display."
            ;;
        *)
            echo "Could not classify this GPU. Assuming it is newer than the"
            echo "ISO's PCI database knows about -> installing nvidia-open-dkms."
            pacman -Sy --needed --noconfirm nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils
            ;;
    esac
} > /var/log/calamares-nvidia-autodetect.log 2>&1
exit 0
