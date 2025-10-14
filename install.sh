#!/bin/bash
# install.sh — Nextcloud (snap) + Tailscale on Raspberry Pi 5 (NVMe boot)
# Assumes you've already cloned SD → NVMe with prep.sh and rebooted from NVMe.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./install.sh"
  exit 1
fi

msg() { echo -e "\n=== $* ==="; }

msg "Starting Pi Cloud setup..."

# 1) Basic checks
PAGE_SIZE="$(getconf PAGE_SIZE || echo 0)"
if [ "$PAGE_SIZE" != "4096" ]; then
  echo "⚠️  Warning: kernel page size is $PAGE_SIZE (expected 4096)."
  echo "   The Nextcloud snap's Redis may crash on 16K kernels."
  echo "   Ensure 'kernel=kernel8.img' is set in /boot/firmware/config.txt and rebooted."
fi

if ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
  echo "❌ No internet connectivity. Connect to Wi-Fi or Ethernet first."
  exit 1
fi

# 2) Install dependencies
msg "Installing required packages..."
apt update
apt install -y snapd curl rsync

# 3) Install Nextcloud snap
if ! snap list | grep -q '^nextcloud '; then
  msg "Installing Nextcloud (snap)..."
  snap install core
  snap install nextcloud
else
  msg "Nextcloud already installed. Skipping."
fi

# Wait a few seconds for Nextcloud to initialize
msg "Waiting for Nextcloud services..."
sleep 10
snap restart nextcloud || true

# 4) Install Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
  msg "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | bash
fi

msg "Bringing up Tailscale (log in when prompted)..."
tailscale up || true

# 5) Add Tailscale MagicDNS hostname as trusted domain
TS_HOST="$(tailscale status --json 2>/dev/null | grep -oE '"DNSName":"[^"]+' | cut -d'"' -f4 | head -n1 || true)"
if [ -n "$TS_HOST" ]; then
  msg "Adding $TS_HOST to Nextcloud trusted domains (index 1)..."
  snap run nextcloud.occ config:system:set trusted_domains 1 --value="$TS_HOST" || true
  snap restart nextcloud || true
else
  echo "⚠️  Could not detect Tailscale hostname. Add it manually later with:"
  echo "    sudo snap run nextcloud.occ config:system:set trusted_domains 1 --value='<your-host>.ts.net'"
fi

# 6) Display connection info
LAN_IP="$(hostname -I | awk '{print $1}')"

echo
echo "✅ Installation complete!"
echo
echo "Access your Pi Cloud:"
echo "  • Local (LAN):        http://$LAN_IP/"
if [ -n "${TS_HOST:-}" ]; then
  echo "  • Remote (Tailscale): http://$TS_HOST/"
fi
echo
echo "Optional (adds HTTPS padlock via Tailscale):"
echo "  sudo tailscale serve https / http://localhost"
echo
echo "To create your Nextcloud admin account, visit the local or Tailscale URL above."
echo
echo "All data is stored on your NVMe drive at:"
echo "  /var/snap/nextcloud/common/nextcloud/data"
echo
msg "Setup complete 🎉"
