#!/bin/bash
# prep.sh — Clone SD → NVMe and prep Pi 5 for NVMe boot (idempotent)
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo ./prep.sh"; exit 1; }

msg() { echo -e "\n=== $* ==="; }

DISK="/dev/nvme0n1"
MNT="/mnt/clone"

msg "🧩 Pi Cloud Prep Starting (clone + NVMe boot enable)"

# Basic network check (needed for git/rpi-clone on first run)
if ! ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && ! ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
  echo "❌ No network detected. Connect to the internet and retry."
  exit 1
fi

# Detect if we already booted from NVMe (then we can skip cloning)
ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if [[ "${ROOT_SRC:-}" == /dev/nvme* ]]; then
  msg "Already running from NVMe ($ROOT_SRC) — cloning will be skipped."
  SKIP_CLONE=1
else
  SKIP_CLONE=0
fi

# Ensure NVMe exists
if ! lsblk -dn -o NAME | grep -q "^$(basename "$DISK" | sed 's|/dev/||')$"; then
  echo "❌ NVMe drive not found at $DISK. Connect it and try again."
  exit 1
fi
echo "✅ NVMe detected: $DISK"

# Tools needed for cloning and config
msg "Installing required tools..."
apt-get update
apt-get install -y gdisk rsync git

# Install rpi-clone if missing
if ! command -v rpi-clone >/dev/null 2>&1; then
  msg "Installing rpi-clone..."
  rm -rf /tmp/rpi-clone
  git clone https://github.com/geerlingguy/rpi-clone.git /tmp/rpi-clone
  install -m 0755 /tmp/rpi-clone/rpi-clone /usr/local/sbin/rpi-clone
fi

# Clone SD → NVMe (only if not already running from NVMe)
if [[ "$SKIP_CLONE" -eq 0 ]]; then
  echo
  echo "⚠️  This will ERASE and overwrite all data on $DISK."
  read -rp "Proceed with cloning to $DISK? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborting. No changes made."
    exit 0
  fi

  msg "Preparing $DISK..."
  wipefs -a "$DISK" || true

  msg "Cloning system to NVMe (this may take a while)..."
  # Auto-confirm prompts: (1) ends-with-digit; (2) proceed
  rpi-clone "$DISK" -f <<< $'yes\nyes\n'
  msg "Clone complete."
fi

# --------- Ensure 4K kernel line in config.txt ----------
# If already running from NVMe, edit live /boot/firmware/config.txt.
# If we just cloned, mount the new NVMe and edit its config.
CFG=""
cleanup() {
  set +e
  mountpoint -q "$MNT/boot/firmware" && umount "$MNT/boot/firmware"
  mountpoint -q "$MNT" && umount "$MNT"
  rmdir "$MNT" 2>/dev/null || true
}
if [[ "$SKIP_CLONE" -eq 1 ]]; then
  CFG="/boot/firmware/config.txt"
else
  BOOT_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
  mkdir -p "$MNT"
  mount "$ROOT_PART" "$MNT"
  mkdir -p "$MNT/boot/firmware"
  mount "$BOOT_PART" "$MNT/boot/firmware"
  trap cleanup EXIT
  CFG="$MNT/boot/firmware/config.txt"
fi

msg "Ensuring 4K kernel line in config.txt"
if ! grep -q '^kernel=kernel8.img' "$CFG" 2>/dev/null; then
  echo 'kernel=kernel8.img' >> "$CFG"
  echo "Added kernel=kernel8.img to config.txt"
else
  echo "config.txt already contains kernel=kernel8.img (no change)."
fi

# Unmount if we mounted
if [[ "$SKIP_CLONE" -eq 0 ]]; then
  cleanup
  trap - EXIT
fi

# --------- Set Pi 5 boot order and PCIe probe (idempotent) ----------
msg "Setting Raspberry Pi 5 boot order (NVMe → USB → SD) and enabling PCIe probe..."
TMP="$(mktemp)"
rpi-eeprom-config > "$TMP"
sed -i '/^BOOT_ORDER=/d' "$TMP"
sed -i '/^PCIE_PROBE=/d' "$TMP"
{
  echo "BOOT_ORDER=0xf416"  # NVMe(4) → USB(1/6) → SD(0xf fallback)
  echo "PCIE_PROBE=1"       # ensure PCIe is probed at boot
} >> "$TMP"
rpi-eeprom-config --apply "$TMP" >/dev/null
rm -f "$TMP"
echo "✅ Boot settings applied."

# --------- Next steps / shutdown option ----------
echo
if [[ "$SKIP_CLONE" -eq 0 ]]; then
  echo "✅ Clone finished. Ready to boot from NVMe."
  echo
  echo "Next steps:"
  echo "  1) Shut down the Pi"
  echo "  2) Remove the SD card"
  echo "  3) Power on (it should boot from NVMe)"
  echo
  read -rp "Shut down now to remove the SD card? [y/N]: " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Shutting down..."
    sleep 1
    shutdown -h now
  else
    echo "You can shut down later with: sudo shutdown -h now"
    echo "After booting from NVMe, run: sudo ./install.sh"
  fi
else
  echo "✅ NVMe boot already active."
  echo "Proceed to: sudo ./install.sh"
fi
