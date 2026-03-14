#!/bin/bash
set -e

echo "---Installing Gstreamer---"

# Installing GStreamer
sudo apt install -y \
  gstreamer1.0-tools \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-libav

# Copy camera-relay.sh to /opt/da/camera-relay.sh
sudo mkdir -p /opt/da
sudo cp $SCRIPT_DIR/scripts/camera-relay.sh /opt/da/camera-relay.sh
sudo chmod +x /opt/da/camera-relay.sh

# Copy camera-relay.env to /etc/specter/camera-relay.env
sudo mkdir -p /etc/specter
sudo cp $SCRIPT_DIR/config/camera-relay.env.template /etc/specter/camera-relay.env

# Create a systemd service
sudo cp $SCRIPT_DIR/systemd/camera-relay.service /etc/systemd/system/camera-relay.service

sudo systemctl daemon-reload
sudo systemctl enable camera-relay
sudo systemctl start camera-relay

echo "---Camera Stream Daemon Started---"
sudo systemctl status camera-relay
