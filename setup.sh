#!/bin/bash
# install.sh — Nextcloud (snap) + NVMe data + Tailscale on Pi 5
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo ./install.sh"; exit 1; }

# Confirm 4K page size is active (required for snap’s Redis)
PSZ=$(getconf PAGE_SIZE || echo 0)
if [ "$PSZ" != "4096" ]; then
  echo "Expected 4K page size, got $PSZ. Did you run prep.sh and reboot?"
  exit 1
fi

echo "Installing essentials…"
apt update
apt install -y snapd curl rsync parted

echo "Installing Nextcloud (snap)…"
snap install core
snap install nextcloud

# ---- NVMe setup (assumes drive is /dev/nvme0n1) ----
DISK=/dev/nvme0n1
PART=${DISK}p1
MNT=/mnt/ncdata

echo "Preparing NVMe at $DISK …"
# If no partition table, create one
if ! lsblk -no NAME "$PART" >/dev/null 2>&1; then
  umount "${DISK}"* >/dev/null 2>&1 || true
  parted -s "$DISK" mklabel gpt mkpart primary ext4 0% 100%
  sleep 1
fi

# Format if not already ext4
if ! blkid "$PART" | grep -qi ext4; then
  mkfs.ext4 -F -L nextcloud_data "$PART"
fi

mkdir -p "$MNT"
mount "$PART" "$MNT"

UUID=$(blkid -s UUID -o value "$PART")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MNT ext4 defaults,noatime 0 2" >> /etc/fstab

chown -R www-data:www-data "$MNT"
chmod -R 750 "$MNT"

# ---- move Nextcloud data to NVMe ----
echo "Moving Nextcloud data to $MNT …"
snap stop nextcloud
rsync -a /var/snap/nextcloud/common/nextcloud/data/ "$MNT"/ || true
sed -i "s|/var/snap/nextcloud/common/nextcloud/data|$MNT|" \
  /var/snap/nextcloud/current/nextcloud/config/config.php
snap start nextcloud

# ---- Tailscale (for anywhere access) ----
echo "Installing Tailscale…"
curl -fsSL https://tailscale.com/install.sh | bash
echo "Log in to Tailscale in the browser when prompted…"
tailscale up || true

# Add Tailscale MagicDNS name as trusted domain (if available)
TS_HOST=$(tailscale status --json 2>/dev/null | grep -oE '"DNSName":"[^"]+' | cut -d'"' -f4 | head -n1 || true)
if [ -n "$TS_HOST" ]; then
  snap run nextcloud.occ config:system:set trusted_domains 1 --value="$TS_HOST" || true
fi

# ---- Final info ----
LAN_IP=$(hostname -I | awk '{print $1}')
echo
echo "✅ Done!"
echo "Local Nextcloud:   http://$LAN_IP/"
[ -n "$TS_HOST" ] && echo "Tailscale address:  http://$TS_HOST/"
echo
echo "Optional (nice padlock over Tailscale):"
echo "  sudo tailscale serve https / http://localhost"
echo
