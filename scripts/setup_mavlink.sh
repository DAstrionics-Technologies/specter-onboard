#!/bin/bash
set -e

echo "--- Wifi Setup ---"

# Install hostapd and dnsmasq
sudo apt install -y hostapd dnsmasq

sudo cp scripts/wifi-start.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/wifi-start.sh
sudo cp services/drone-wifi.service /etc/systemd/system/
sudo cp config/hostapd.conf /etc/hostapd/
sudo systemctl disable hostapd dnsmasq
sudo systemctl daemon-reload
sudo systemctl enable drone-wifi


echo "--- Drone Onboard Setup ---"

# Install mavlink-router
sudo apt install -y git meson ninja-build pkg-config gcc g++ systemd systemd-dev
git clone https://github.com/mavlink-router/mavlink-router /tmp/mavlink-router
cd /tmp/mavlink-router
git submodule update --init --recursive
meson setup build . && ninja -C build
sudo ninja -C build install

# Copy config
sudo mkdir -p /etc/mavlink-router
sudo cp config/mavlink-router.conf /etc/mavlink-router/main.conf

# Install systemd service
sudo cp systemd/mavlink-router.service /etc/systemd/system/mavlink-router.service
sudo systemctl daemon-reload
sudo systemctl enable mavlink-router
sudo systemctl start mavlink-router

echo "--- Setup Complete ---"
echo "mavlink-router status:"
sudo systemctl status mavlink-router
