#!/bin/bash
# Configures zram (systemd-zram-generator) and zswap compatibility in the target system.
{
    echo "Configuring zram and zswap compatibility..."

    # 1. Configure systemd-zram-generator
    mkdir -p /etc/systemd
    cat << 'EOF' > /etc/systemd/zram-generator.conf
# /etc/systemd/zram-generator.conf
# Managed by AcreetionOS Calamares Installer
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    # 2. Configure sysctl settings for zswap and zram optimization
    mkdir -p /etc/sysctl.d
    cat << 'EOF' > /etc/sysctl.d/99-zswap-zram.conf
# /etc/sysctl.d/99-zswap-zram.conf
# AcreetionOS memory management: zswap + zram tuning
vm.swappiness = 60
vm.page-cluster = 0
vm.vfs_cache_pressure = 100
EOF

    # 3. Ensure zswap kernel parameters are present in GRUB default config
    if [ -f /etc/default/grub ]; then
        if ! grep -q "zswap.enabled=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 /' /etc/default/grub
        fi
    fi

    # 4. Enable systemd zram setup service if available
    systemctl enable systemd-zram-setup@zram0.service 2>/dev/null || true

    echo "zram and zswap configuration complete."
} > /var/log/calamares-zswap-zram.log 2>&1
exit 0

