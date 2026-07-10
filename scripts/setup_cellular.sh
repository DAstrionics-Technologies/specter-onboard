#!/bin/bash
set -e

echo "---Setting Up Cellular---"

# Install ModemManager if not present
sudo apt install -y modemmanager

# Copy env config
sudo mkdir -p /etc/specter
sudo cp $SCRIPT_DIR/config/cellular.env.template /etc/specter/cellular.env
source /etc/specter/cellular.env

# Unlock SIM if PIN is set (non-fatal — no modem yet is OK)
if [ -n "${SIM_PIN:-}" ]; then
  MODEM_PATH="$(mmcli -L 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Modem/\d+' || true)"
  if [ -n "$MODEM_PATH" ]; then
    mmcli -m "$MODEM_PATH" --pin="$SIM_PIN" || true
  else
    echo "No modem detected — skipping PIN unlock."
  fi
fi

# Create NetworkManager GSM connection if it doesn't exist
if ! nmcli con show "$CON_NAME" &>/dev/null; then
  sudo nmcli connection add type gsm ifname '*' con-name "$CON_NAME" apn "$APN"
  sudo nmcli connection modify "$CON_NAME" connection.autoconnect yes
fi

# Bring it up (non-fatal — connects when the modem appears)
sudo nmcli connection up "$CON_NAME" || echo "Modem not up yet — connection '$CON_NAME' will autoconnect when it appears."

echo "---Cellular Setup Complete---"
ip addr show wwan0 2>/dev/null || true
ping -c 3 google.com || echo "WARNING: No internet connectivity"
