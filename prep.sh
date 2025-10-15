#!/bin/bash
# prep.sh — clone SD → NVMe and enable 4K kernel for Pi 5
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo ./prep.sh"; exit 1; }

echo "=== 🧩 Pi Cloud Prep Starting (clone + NVMe boot enable) ==="

# 1. Confirm network & update firmware
echo "Checking internet..."
ping -c1 8.8.8.8 >/dev/null 2>&1 || { echo "❌ No network detected."; exit 1; }

# 2. Detect NVMe
if ! lsblk | grep -q nvme0n1; then
  echo "❌ No NVMe drive detected. Connect it and try again."
  exit 1
fi
echo "✅ NVMe detected: /dev/nvme0n1"

# 3. Install rpi-clone (latest)
echo "Installing rpi-clone..."
git clone https://github.com/billw2/rpi-clone.git /tmp/rpi-clone
cp /tmp/rpi-clone/rpi-clone /usr/local/sbin/

# Detect and wipe NVMe, clone from SD -> NVMe
DISK=/dev/nvme0n1
echo "Preparing $DISK for cloning..."
sudo wipefs -a $DISK
sudo sgdisk --zap-all $DISK

yes yes | sudo rpi-clone $DISK -f

# 5. Add kernel=kernel8.img to ensure Redis stability
CFG=/boot/firmware/config.txt
if ! grep -q '^kernel=kernel8.img' "$CFG"; then
  echo "Adding kernel=kernel8.img to $CFG ..."
  echo "kernel=kernel8.img" >> "$CFG"
else
  echo "kernel=kernel8.img already present."
fi

# 6. Confirm EEPROM boot order (optional safety)
echo "Setting boot order to prefer NVMe..."
raspi-config nonint do_boot_order 6  # 6 = NVMe/USB first

# 7. Done
echo
echo "✅ Clone complete! The system is ready to boot from NVMe."
echo
echo "Next steps:"
echo "  1. Shut down: sudo shutdown -h now"
echo "  2. Remove the SD card"
echo "  3. Power back on (the Pi should boot directly from NVMe)"
echo
echo "Once booted, run install.sh to finish setting up Nextcloud + Tailscale."
echo "=== ✅ Prep finished ==="
