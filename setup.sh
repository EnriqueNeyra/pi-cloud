#!/bin/bash
# setup.sh — One-command setup for Pi 5 personal cloud (Nextcloud + Tailscale + NVMe)
# Works on Raspberry Pi OS Lite 64-bit
set -euo pipefail

echo "=== 🧩 Pi Cloud Setup Starting ==="

# 1. Require root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./setup.sh"
  exit 1
fi

# 3. Add kernel=kernel8.img if missing (for Redis stability on Pi 5)
CONFIG=/boot/firmware/config.txt
if ! grep -q '^kernel=kernel8.img' "$CONFIG"; then
  echo "Adding kernel=kernel8.img to $CONFIG ..."
  echo "kernel=kernel8.img" | tee -a "$CONFIG" >/dev/null
  echo "✅ kernel=kernel8.img added (takes effect after reboot)"
else
  echo "kernel=kernel8.img already present."
fi

# 4. Update packages
echo "Updating system packages..."
apt update && apt full-upgrade -y

# 5. Install dependencies
apt install -y snapd

# 6. Enable Snap core + Nextcloud
echo "Installing Nextcloud (snap)..."
snap install core
snap install nextcloud

# 7. Verify services
snap services nextcloud | grep -E 'apache|mysql|php-fpm'

# 8. Prepare NVMe drive for data (assuming /dev/nvme0n1)
echo "Preparing NVMe drive..."
umount /dev/nvme0n1* >/dev/null 2>&1 || true
parted -s /dev/nvme0n1 mklabel gpt mkpart primary ext4 0% 100%
mkfs.ext4 -F -L nextcloud_data /dev/nvme0n1p1
mkdir -p /mnt/ncdata
mount /dev/nvme0n1p1 /mnt/ncdata

UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/ncdata ext4 defaults,noatime 0 2" >> /etc/fstab
chown -R www-data:www-data /mnt/ncdata
chmod -R 750 /mnt/ncdata

# 9. Point Nextcloud to NVMe data dir
snap stop nextcloud
rsync -a /var/snap/nextcloud/common/nextcloud/data/ /mnt/ncdata/ || true
sed -i "s|/var/snap/nextcloud/common/nextcloud/data|/mnt/ncdata|" \
  /var/snap/nextcloud/current/nextcloud/config/config.php
snap start nextcloud

# 10. Install & log in to Tailscale
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | bash
echo "➡️ Please log in to Tailscale in your browser when prompted."
tailscale up

# 11. Add Tailscale hostname as trusted domain
TS_HOST=$(tailscale status --json | grep -oE '"DNSName":"[^"]+' | cut -d'"' -f4 | head -n1)
if [ -n "$TS_HOST" ]; then
  echo "Adding $TS_HOST as trusted domain..."
  snap run nextcloud.occ config:system:set trusted_domains 1 --value="$TS_HOST" || true
fi

# 12. Print connection info
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo
echo "✅ Setup complete!"
echo "Access Nextcloud locally:  http://$LOCAL_IP/"
[ -n "$TS_HOST" ] && echo "Access anywhere via Tailscale: http://$TS_HOST/"
echo
echo "To enable HTTPS padlock through Tailscale:"
echo "  sudo tailscale serve https / http://localhost"
echo
echo "Reboot once now to ensure kernel=kernel8.img takes effect."
echo "=== ✅ All done! ==="
