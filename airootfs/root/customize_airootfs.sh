#!/usr/bin/env bash
# customize_airootfs.sh — runs inside the build chroot before squashing
set -e
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
for svc in NetworkManager.service sshd.service choose-mirror.service \
           pacman-init.service reflector.service chronyd.service; do
  if [ -e "/usr/lib/systemd/system/$svc" ] || [ -e "/etc/systemd/system/$svc" ]; then
    systemctl enable "$svc" || true
  fi
done
passwd -d root
cat > /etc/hosts <<- 'HOSTS_EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   acreetionos-live.localdomain acreetionos-live
HOSTS_EOF
echo "customize_airootfs.sh: done"
