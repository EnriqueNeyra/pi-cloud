#!/bin/bash
# prep.sh — clone SD → NVMe and enable 4K kernel for Pi 5
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo ./prep.sh"; exit 1; }

echo "=== 🧩 Pi Cloud Prep Starting (clone + NVMe boot enable) ==="

echo "Checking internet..."
ping -c1 8.8.8.8 >/dev/null 2>&1 || { echo "❌ No network detected."; exit 1; }

# Detect NVMe
DISK="/dev/nvme0n1"
if ! lsblk | grep -q "$(basename "$DISK")"; then
  echo "❌ No NVMe drive detected at $DISK. Connect it and try again."
  exit 1
fi
echo "✅ NVMe detected: $DISK"

# Tools we need
apt update
apt install -y gdisk rsync

# Install rpi-clone if missing
if ! command -v rpi-clone >/dev/null 2>&1; then
  echo "Installing rpi-clone..."
  rm -rf /tmp/rpi-clone
  git clone https://github.com/geerlingguy/rpi-clone.git /tmp/rpi-clone
  cp /tmp/rpi-clone/rpi-clone /usr/local/sbin/
fi

echo
echo "⚠️  WARNING: This will completely erase and overwrite all data on $DISK!"
echo "It will clone your current SD card system to the NVMe drive."
read -rp "Are you sure you want to continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborting clone. No changes made."
  exit 0
fi

# Wipe disk
echo "Preparing $DISK for cloning..."
wipefs -a "$DISK" || true

# Clone SD → NVMe (auto-confirm the 'nvme0n1 ends with a digit' prompt)
echo "Cloning system to NVMe (this may take several minutes)..."
rpi-clone "$DISK" -f <<< $'yes\nyes\n'
echo "Clone complete"

# Remount the cloned NVMe so we can modify config.txt
MNT="/mnt/clone"
mount "${DISK}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${DISK}p1" "$MNT/boot/firmware"

CFG="$MNT/boot/firmware/config.txt"
if ! grep -q '^kernel=kernel8.img' "$CFG"; then
  echo 'kernel=kernel8.img' | tee -a "$CFG" >/dev/null
  echo "config.txt modified successfully"
fi

umount "$MNT/boot/firmware"
umount "$MNT"

# Set boot order to prefer NVMe → USB → SD
echo
echo "⚙️  Setting Raspberry Pi 5 boot order (NVMe → USB → SD)..."
TMP=$(mktemp)
rpi-eeprom-config > "$TMP"
sed -i '/^BOOT_ORDER=/d' "$TMP"
sed -i '/^PCIE_PROBE=/d' "$TMP"
echo "BOOT_ORDER=0xf416" >> "$TMP"
echo "PCIE_PROBE=1" >> "$TMP"
rpi-eeprom-config --apply "$TMP"
rm -f "$TMP"
echo "✅ Boot order updated!"

echo
echo "✅ Clone complete! The system is ready to boot from NVMe."
echo
echo "Next steps:"
echo "  1) Shut down the Pi"
echo "  2) Remove the SD card"
echo "  3) Power back on (the Pi should boot directly from NVMe)"
echo
read -rp "Would you like to shut down now so you can remove the SD card? [y/N]: " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Once rebooted, run install.sh to finish setting up Nextcloud + Tailscale"
  sleep 1
  echo "Shutting down..."
  sleep 2
  shutdown -h now
else
  echo "You can shut down manually later with: sudo shutdown -h now"
  echo "Once rebooted, run install.sh to finish setting up Nextcloud + Tailscale"
fi
