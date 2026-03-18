#!/bin/bash
set -e
echo "--- WiFi AP Setup ---"

# Install CU2 driver via DKMS
DRIVER_DIR="$SCRIPT_DIR/drivers/rtl88x2CU"
if ! lsmod | grep -q 88x2cu; then
    sudo apt install -y dkms build-essential linux-headers-$(uname -r)
    sudo cp -r "$DRIVER_DIR" /usr/src/rtl88x2cu-1.0
    sudo dkms add rtl88x2cu/1.0
    sudo dkms build rtl88x2cu/1.0
    sudo dkms install rtl88x2cu/1.0
    sudo modprobe 88x2cu
else
    echo "RTL88x2CU driver already loaded, skipping."
fi

# Install dependencies
sudo apt install -y hostapd dnsmasq rfkill

# Disable vendor-managed services (we manage manually via drone-wifi.service)
sudo systemctl disable hostapd dnsmasq 2>/dev/null || true

# Stage runtime script
sudo cp "$SCRIPT_DIR/scripts/wifi-start.sh" /usr/local/bin/wifi-start.sh
sudo chmod +x /usr/local/bin/wifi-start.sh

# Stage hostapd config (envsubst from template)
sudo mkdir -p /etc/hostapd /etc/specter
sudo cp "$SCRIPT_DIR/config/wifi.env.template" /etc/specter/wifi.env
source /etc/specter/wifi.env
export WIFI_INTERFACE WIFI_SSID WIFI_PASSWORD WIFI_CHANNEL
envsubst < "$SCRIPT_DIR/config/hostapd.conf.template" | sudo tee /etc/hostapd/hostapd.conf > /dev/null

# Tell hostapd where its config lives (needed on RPi OS to unmask the unit)
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee /etc/default/hostapd > /dev/null

# Install and enable systemd service
sudo cp "$SCRIPT_DIR/systemd/drone-wifi.service" /etc/systemd/system/drone-wifi.service
sudo systemctl daemon-reload
sudo systemctl enable drone-wifi

echo "--- WiFi AP Setup Complete ---"
