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
apt install -y curl jq
apt install -y snapd
msg "Waiting for snapd to finish setup..."
sleep 15

# 3) Install Nextcloud snap
if ! snap list | grep -q '^nextcloud '; then
  msg "Installing Nextcloud (snap)..."
  snap install core
  snap install nextcloud
else
  msg "Nextcloud already installed. Skipping."
fi

# 4) Create Nextcloud Admin Account
msg "Waiting for Nextcloud services..."
sleep 10
snap restart nextcloud || true

echo
msg "=== Create your Nextcloud admin account ==="
read -p "Enter admin username: " ADMIN_USER
while true; do
  read -s -p "Enter admin password: " ADMIN_PASS
  echo ""
  read -s -p "Confirm password: " ADMIN_PASS_CONFIRM
  echo ""
  if [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ]; then
    break
  else
    echo "❌ Passwords do not match. Please try again."
  fi
done

echo "Setting up Nextcloud admin account..."
snap run nextcloud.manual-install "$ADMIN_USER" "$ADMIN_PASS" || true

# 5) Install Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
  msg "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | bash
fi

msg "Bringing up Tailscale (log in when prompted)..."
sleep 5
# Idempotent: only run 'tailscale up' if not already running
if ! tailscale status >/dev/null 2>&1; then
  tailscale up
else
  echo "Tailscale already up."
fi

# 6) Add Tailscale MagicDNS hostname as a trusted domain
TS_HOST="$(tailscale status --self --json | jq -r '.Self.DNSName | sub("\\.$";"")')"
LAN_IP="$(hostname -I | awk '{print $1}')"

if [ -n "$TS_HOST" ]; then
  msg "Adding $TS_HOST to Nextcloud trusted domains..."
  snap run nextcloud.occ config:system:set trusted_domains 1 --value="$TS_HOST"
  snap run nextcloud.occ config:system:set trusted_domains 2 --value="$LAN_IP"
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

# 7) Enable HTTPS padlock via Tailscale (for *.ts.net access)
if [ -n "$TS_HOST" ]; then
  msg "Enabling HTTPS access for $TS_HOST via Tailscale..."
  tailscale serve --bg 80 || true
  echo "✅ HTTPS proxy ensured — https://$TS_HOST/"
  # Make Nextcloud trust the local proxy and use HTTPS
  sudo snap run nextcloud.occ config:system:set trusted_proxies 0 --value=127.0.0.1
  sudo snap run nextcloud.occ config:system:set overwriteprotocol --value=https
  sudo snap restart nextcloud || true
fi

echo
echo "✅ Installation complete!"
echo
echo "Access your Pi Cloud:"
echo "  • Local (LAN):        http://$LAN_IP/"
if [ -n "${TS_HOST:-}" ]; then
  echo "  • Remote (Tailscale): https://$TS_HOST/"
fi
echo
echo "All data is stored on your NVMe drive at:"
echo "  /var/snap/nextcloud/common/nextcloud/data"
echo
echo "Refer to the README.md for next steps"
msg "Setup complete 🎉"
