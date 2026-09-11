#!/usr/bin/env bash
# AcreetionOS Horizon - Core Recovery Backend
# Provides unified hardware probing and repair routines for both TUI and GUI frontends.

set -o pipefail

# Ensure PATH includes standard administrative binaries
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Remount root as read-write if it's currently read-only
ensure_root_rw() {
    local test_file="/.acreetion_rw_probe.$$"
    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        return 0
    fi
    mount -o remount,rw / 2>/dev/null || true
    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        return 0
    fi
    return 1
}

# Scan hardware, graphics status, boot mode, and failure indicators
scan_hardware() {
    local as_json=false
    [[ "${1:-}" == "--json" ]] && as_json=true

    # 1. Boot mode
    local boot_mode="BIOS"
    [[ -d /sys/firmware/efi ]] && boot_mode="UEFI"

    # 2. Kernel command line check for safe mode / nomodeset
    local nomodeset=false
    local cmdline=""
    if [[ -r /proc/cmdline ]]; then
        cmdline=$(cat /proc/cmdline)
        if [[ "$cmdline" =~ nomodeset|acreetion\.tui=1|text ]]; then
            nomodeset=true
        fi
    fi

    # 3. Detect GPUs and active drivers
    local gpu_list=()
    local gpu_vendors=()
    local has_nvidia=false
    local has_amd=false
    local has_intel=false
    local has_vm=false

    for dev in /sys/bus/pci/devices/*; do
        [[ -d "$dev" ]] || continue
        local vendor class driver_name pci_id
        vendor=$(cat "$dev/vendor" 2>/dev/null || true)
        class=$(cat "$dev/class" 2>/dev/null || true)
        if [[ -n "$vendor" ]] && { [[ "${class:2:4}" == "0300" ]] || [[ "${class:2:4}" == "0302" ]]; }; then
            pci_id=$(basename "$dev")
            driver_name="unbound"
            if [[ -e "$dev/driver" ]]; then
                driver_name=$(basename "$(readlink "$dev/driver" 2>/dev/null || echo "unknown")")
            fi

            local vname="Unknown"
            case "$vendor" in
                0x10de) vname="NVIDIA"; has_nvidia=true ;;
                0x1002) vname="AMD"; has_amd=true ;;
                0x8086) vname="Intel"; has_intel=true ;;
                0x15ad) vname="VMware"; has_vm=true ;;
                0x1af4) vname="VirtIO/QEMU"; has_vm=true ;;
                0x80ee) vname="VirtualBox"; has_vm=true ;;
                *) vname="PCI ($vendor)" ;;
            esac
            gpu_vendors+=("$vname")
            gpu_list+=("$pci_id ($vname, driver: $driver_name)")
        fi
    done

    # 4. Detect DRM KMS status & connected displays
    local kms_active=false
    local connected_displays=()
    for status_file in /sys/class/drm/card*-*/status; do
        if [[ -f "$status_file" ]]; then
            kms_active=true
            local status conn
            status=$(cat "$status_file" 2>/dev/null || echo "unknown")
            if [[ "$status" == "connected" ]]; then
                conn=$(basename "$(dirname "$status_file")")
                connected_displays+=("$conn")
            fi
        fi
    done

    # 5. Check display server capability
    local xorg_available=false
    command -v Xorg &>/dev/null && xorg_available=true

    # Decision: GUI mode capable
    local gui_capable=false
    if [[ "$nomodeset" == false && "$xorg_available" == true && ${#connected_displays[@]} -gt 0 ]]; then
        gui_capable=true
    fi

    # 6. Storage & Root filesystem status
    local root_rw=false
    ensure_root_rw && root_rw=true
    local root_usage
    root_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')

    # 7. Check previous boot failure signals
    local failed_units=()
    if command -v systemctl &>/dev/null; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && failed_units+=("$line")
        done < <(systemctl --failed --no-legend 2>/dev/null | awk '{print $2}' | head -n 5)
    fi

    local journal_errors=0
    if command -v journalctl &>/dev/null; then
        journal_errors=$(journalctl -b -1 -p 3 --no-pager 2>/dev/null | grep -c '^[A-Z]' || true)
    fi

    if $as_json; then
        cat <<EOF
{
  "boot_mode": "$boot_mode",
  "nomodeset": $nomodeset,
  "gui_capable": $gui_capable,
  "kms_active": $kms_active,
  "xorg_available": $xorg_available,
  "root_rw": $root_rw,
  "root_usage": "$root_usage",
  "has_nvidia": $has_nvidia,
  "has_amd": $has_amd,
  "has_intel": $has_intel,
  "has_vm": $has_vm,
  "gpus": [$(printf '"%s",' "${gpu_list[@]}" | sed 's/,$//')],
  "displays": [$(printf '"%s",' "${connected_displays[@]}" | sed 's/,$//')],
  "failed_units": [$(printf '"%s",' "${failed_units[@]}" | sed 's/,$//')],
  "journal_errors_prev_boot": $journal_errors
}
EOF
    else
        echo "=== AcreetionOS Hardware & System Diagnostics ==="
        echo "Boot Mode:          $boot_mode"
        echo "Root Read-Write:    $root_rw ($root_usage used)"
        echo "Graphics State:     KMS=${kms_active}, Xorg=${xorg_available}, nomodeset=${nomodeset}"
        echo "Connected Displays: ${connected_displays[*]:-None detected}"
        echo "Detected GPUs:"
        for g in "${gpu_list[@]}"; do
            echo "  - $g"
        done
        echo "GUI Mode Viable:    $gui_capable"
        if [[ ${#failed_units[@]} -gt 0 ]]; then
            echo "Failed Services:    ${failed_units[*]}"
        fi
        echo "Prev Boot Errors:   $journal_errors critical log entries"
    fi
}

# Repair: Reset Xorg configuration and remove pinning that causes screen conflicts
repair_xorg_config() {
    ensure_root_rw
    local log=""
    log+="Removing custom Xorg device pins and configurations...\n"

    local files_to_remove=(
        "/etc/X11/xorg.conf.d/10-nvidia-pin.conf"
        "/etc/X11/xorg.conf.d/99-nvidia-no-autoaddgpu.conf"
        "/etc/X11/xorg.conf"
    )

    for f in "${files_to_remove[@]}"; do
        if [[ -f "$f" ]]; then
            mv -f "$f" "${f}.bak.$(date +%s)"
            log+="Backed up and removed $f\n"
        fi
    done

    # Clear user monitor cache which can freeze GNOME Shell on resolution mismatch
    for user_home in /home/*; do
        if [[ -d "$user_home/.config" ]]; then
            rm -f "$user_home/.config/monitors.xml"
            log+="Reset monitors.xml for $(basename "$user_home")\n"
        fi
    done
    rm -f /var/lib/gdm/.config/monitors.xml 2>/dev/null || true

    log+="Xorg display configuration successfully reset to default autodetect.\n"
    printf "%b" "$log"
}

# Repair: Switch GPU driver mode (e.g. from broken proprietary nvidia to nouveau or modesetting)
switch_gpu_driver() {
    local target="${1:-modesetting}"
    ensure_root_rw
    local log=""

    case "$target" in
        nouveau|modesetting)
            log+="Configuring fallback open-source driver ($target)...\n"
            rm -f /etc/modprobe.d/blacklist-nouveau.conf
            rm -f /etc/X11/xorg.conf.d/10-nvidia-pin.conf
            # Adjust mkinitcpio.conf to remove forced nvidia modules
            if [[ -f /etc/mkinitcpio.conf ]]; then
                sed -i 's/nvidia nvidia_modeset nvidia_drm nvidia_uvm //g' /etc/mkinitcpio.conf
                sed -i 's/nvidia_drm //g' /etc/mkinitcpio.conf
                log+="Removed NVIDIA early-KMS from mkinitcpio.conf\n"
            fi
            ;;
        nvidia)
            log+="Restoring NVIDIA proprietary driver configuration...\n"
            mkdir -p /etc/modprobe.d
            printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
            if grep -q '^MODULES=(' /etc/mkinitcpio.conf 2>/dev/null && ! grep -q 'nvidia_drm' /etc/mkinitcpio.conf; then
                sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_drm nvidia_uvm /' /etc/mkinitcpio.conf
                log+="Added NVIDIA early-KMS to mkinitcpio.conf\n"
            fi
            ;;
        *)
            echo "Unknown target driver: $target" >&2
            return 1
            ;;
    esac

    log+="Regenerating initramfs...\n"
    if mkinitcpio -P >/dev/null 2>&1; then
        log+="Initramfs updated successfully.\n"
    else
        log+="Warning: mkinitcpio reported errors.\n"
    fi

    printf "%b" "$log"
}

# Repair: Rebuild Initramfs images (ensuring both default and fallback are configured)
repair_initramfs() {
    ensure_root_rw
    local log="Ensuring standard default and fallback presets...\n"

    for preset in /etc/mkinitcpio.d/*.preset; do
        [[ -f "$preset" ]] || continue
        local kver
        kver=$(basename "$preset" .preset)
        {
            echo "ALL_kver=\"/boot/vmlinuz-${kver}\""
            echo "PRESETS=('default' 'fallback')"
            echo "default_image=\"/boot/initramfs-${kver}.img\""
            echo "fallback_image=\"/boot/initramfs-${kver}-fallback.img\""
            echo "fallback_options=\"-S autodetect\""
        } > "$preset"
        log+="Configured $preset with default and fallback targets\n"
    done

    log+="Running mkinitcpio -P...\n"
    if mkinitcpio -P; then
        log+="All initramfs images rebuilt successfully.\n"
    else
        log+="Warning: Some initramfs images had rebuild warnings/errors.\n"
    fi
    printf "%b" "$log"
}

# Repair: Rebuild GRUB bootloader configuration and reset boot counters
repair_grub() {
    ensure_root_rw
    local log="Resetting GRUB boot failure counters...\n"

    if command -v grub-editenv &>/dev/null; then
        mkdir -p /boot/grub
        grub-editenv /boot/grub/grubenv set boot_counter=0 2>/dev/null || true
        grub-editenv /boot/grub/grubenv set recordfail=0 2>/dev/null || true
        log+="GRUB boot counter cleared.\n"
    fi

    log+="Regenerating GRUB configuration (/boot/grub/grub.cfg)...\n"
    if grub-mkconfig -o /boot/grub/grub.cfg; then
        log+="GRUB configuration rebuilt successfully.\n"
    else
        log+="Error: grub-mkconfig failed.\n"
        return 1
    fi
    printf "%b" "$log"
}

# Repair: Clear package manager and database lock files
clear_package_locks() {
    ensure_root_rw
    local log=""
    if [[ -f /var/lib/pacman/db.lck ]]; then
        rm -f /var/lib/pacman/db.lck
        log+="Removed stale /var/lib/pacman/db.lck\n"
    else
        log+="No stale pacman locks found.\n"
    fi
    printf "%b" "$log"
}

# Repair: Check and repair filesystems
check_filesystems() {
    ensure_root_rw
    local log="Scanning disk storage and mount points...\n"
    log+=$(df -h / /boot /home 2>/dev/null || df -h)
    log+="\n\nTriggering automated fsck check on next reboot...\n"
    touch /forcefsck 2>/dev/null || true
    printf "%b" "$log"
}

# List normal users eligible for password reset
list_normal_users() {
    awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' /etc/passwd 2>/dev/null || echo "root"
}

# Reset user password
reset_password() {
    local target_user="$1"
    local new_pass="$2"
    if [[ -z "$target_user" || -z "$new_pass" ]]; then
        echo "Usage: reset_password <username> <new_password>" >&2
        return 1
    fi
    ensure_root_rw
    echo "${target_user}:${new_pass}" | chpasswd
    echo "Password for user '$target_user' successfully updated."
}

# Extract diagnostics logs
get_system_log() {
    local log_type="${1:-journal}"
    case "$log_type" in
        journal|errors)
            if command -v journalctl &>/dev/null; then
                journalctl -b -1 -p 4 --no-pager -n 150 2>/dev/null || journalctl -b 0 -p 4 --no-pager -n 150
            else
                echo "journalctl not available."
            fi
            ;;
        xorg)
            if [[ -f /var/log/Xorg.0.log ]]; then
                cat /var/log/Xorg.0.log
            elif [[ -f /var/log/Xorg.0.log.old ]]; then
                cat /var/log/Xorg.0.log.old
            else
                echo "No /var/log/Xorg.0.log found."
            fi
            ;;
        dmesg)
            dmesg -T --level=err,warn 2>/dev/null | tail -n 150 || dmesg | tail -n 150
            ;;
        *)
            echo "Unknown log type: $log_type (use: journal, xorg, or dmesg)" >&2
            return 1
            ;;
    esac
}

# Command dispatch for CLI invocations
case "${1:-}" in
    scan)
        shift
        scan_hardware "$@"
        ;;
    fix-xorg)
        repair_xorg_config
        ;;
    switch-driver)
        switch_gpu_driver "${2:-modesetting}"
        ;;
    rebuild-initramfs)
        repair_initramfs
        ;;
    rebuild-grub)
        repair_grub
        ;;
    clear-locks)
        clear_package_locks
        ;;
    check-fs)
        check_filesystems
        ;;
    list-users)
        list_normal_users
        ;;
    reset-password)
        reset_password "$2" "$3"
        ;;
    get-log)
        get_system_log "${2:-journal}"
        ;;
    ensure-rw)
        ensure_root_rw && echo "Root filesystem is read-write." || { echo "Failed to remount root read-write." >&2; exit 1; }
        ;;
    *)
        # If sourced, do nothing; if called with no arguments or invalid, show help
        if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
            echo "AcreetionOS Recovery Backend"
            echo "Usage: $0 {scan|fix-xorg|switch-driver|rebuild-initramfs|rebuild-grub|clear-locks|check-fs|list-users|reset-password|get-log}"
        fi
        ;;
esac
