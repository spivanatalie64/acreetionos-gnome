#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="AcreetionOS-Horizon"
iso_label="acreetionOS_horizon_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Acreetion OS Community"
iso_application="AcreetionOS Horizon Install Media"
iso_version="1.0"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito' 'uefi-ia32.grub.esp' 'uefi-x64.grub.esp' 'uefi-ia32.grub.eltorito' 'uefi-x64.grub.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
  ["/usr/bin/calamares"]="0:0:755"
#  ["/usr/lib/calamares/modules/*"]="0:0:755"
  ["/usr/bin/fixkeys.sh"]="0:0:755"
  ["/usr/bin/dd.sh"]="0:0:755"
  ["/usr/local/bin/postinstall.sh"]="0:0:755"
  ["/usr/bin/calamares.sh"]="0:0:755"
  ["/usr/local/bin/preinstall-before"]="0:0:755"
  ["/usr/local/bin/stormos-final"]="0:0:755"
  ["/usr/bin/wifi-connection"]="0:0:755"
  ["/usr/local/bin/setup-displays.sh"]="0:0:755"
  ["/usr/local/bin/horizon-image-update"]="0:0:755"
  ["/usr/local/bin/horizon-image-update-gui"]="0:0:755"
  ["/usr/local/bin/freeman"]="0:0:755"
  ["/usr/local/bin/horizon-firstboot.sh"]="0:0:755"
  ["/usr/share/applications/horizon-image-update-gui.desktop"]="0:0:644"
)
