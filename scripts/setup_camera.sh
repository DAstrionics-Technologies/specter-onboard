#!/bin/bash
set -e

echo "---Installing Gstreamer---"

# Installing GStreamer
sudo apt install -y \
  gstreamer1.0-tools \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-libav \
  gstreamer1.0-rtsp

# Copy camera-relay.sh to /opt/specter/bin/camera-relay.sh
sudo mkdir -p /opt/specter/bin
sudo cp $SCRIPT_DIR/scripts/camera-relay.sh /opt/specter/bin/camera-relay.sh
sudo chmod +x /opt/specter/bin/camera-relay.sh

# Copy camera-relay.env to /etc/specter/camera-relay.env
sudo mkdir -p /etc/specter
sudo cp $SCRIPT_DIR/config/camera-relay.env.template /etc/specter/camera-relay.env

# Set static IP for camera Ethernet interface
if ! nmcli con show camera &>/dev/null; then
  nmcli con add type ethernet con-name camera ifname eth0 \
    ipv4.addresses 192.168.144.1/24 ipv4.method manual || true
fi

# Create a systemd service
sudo cp $SCRIPT_DIR/systemd/camera-relay.service /etc/systemd/system/camera-relay.service

sudo systemctl daemon-reload
sudo systemctl enable camera-relay
sudo systemctl start camera-relay || true

echo "---Camera Stream Daemon Started---"
echo "camera-relay: $(systemctl is-active camera-relay)"
