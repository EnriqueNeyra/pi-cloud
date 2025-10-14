#!/bin/bash
# prep.sh — switch Pi 5 to 4K page-size kernel, then reboot
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo ./prep.sh"; exit 1; }

CFG=/boot/firmware/config.txt

if ! grep -q '^kernel=kernel8.img' "$CFG"; then
  echo "Adding kernel=kernel8.img to $CFG ..."
  echo 'kernel=kernel8.img' >> "$CFG"
else
  echo "kernel=kernel8.img already present."
fi

echo "Updating system packages..."
apt update && apt full-upgrade -y

echo "Rebooting now to activate 4K kernel…"
sleep 2
reboot
