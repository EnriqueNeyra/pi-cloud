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

# 2) Install dependencies
msg "Installing required packages..."
apt update
apt install -y snapd curl jq

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
tailscale up

# 5) Add Tailscale MagicDNS hostname as a trusted domain
TS_HOST="$(tailscale status --self --json | jq -r '.Self.DNSName | sub("\\.$";"")')"

if [ -n "$TS_HOST" ]; then
  msg "Adding $TS_HOST to Nextcloud trusted domains..."
  NEXT_IDX="$(snap run nextcloud.occ config:system:get trusted_domains \
    | awk '{print $1}' | sed 's/://g' | sort -n | tail -n1)"
  NEXT_IDX=$(( ${NEXT_IDX:-0} + 1 ))
  snap run nextcloud.occ config:system:set trusted_domains "$NEXT_IDX" --value="$TS_HOST"
  snap restart nextcloud || true
else
  echo "⚠️  Could not detect Tailscale hostname. Add it manually later with:"
  echo "    sudo snap run nextcloud.occ config:system:set trusted_domains 1 --value='<your-host>.ts.net'"
fi

# Wait until Nextcloud is listening on 80
for i in {1..20}; do
  if curl -fsI http://127.0.0.1/ >/dev/null 2>&1; then break; fi
  sleep 1
done

# 6) Enable HTTPS padlock via Tailscale (for *.ts.net access)
if [ -n "$TS_HOST" ]; then
  msg "Enabling HTTPS access for $TS_HOST via Tailscale..."
  if ! tailscale serve status >/dev/null 2>&1; then
    tailscale serve --bg 80
    echo "✅ HTTPS proxy enabled — https://$TS_HOST/"
  else
    echo "ℹ️  HTTPS via Tailscale already active — https://$TS_HOST/"
  fi
fi

# 7) Display connection info
LAN_IP="$(hostname -I | awk '{print $1}')"

echo
echo "✅ Installation complete!"
echo
echo "Access your Pi Cloud:"
echo "  • Local (LAN):        https://$LAN_IP/"
if [ -n "${TS_HOST:-}" ]; then
  echo "  • Remote (Tailscale): https://$TS_HOST/"
fi
echo
echo "All data is stored on your NVMe drive at:"
echo "  /var/snap/nextcloud/common/nextcloud/data"
echo
echo "Refer to the README.md for next steps"
msg "Setup complete 🎉"
