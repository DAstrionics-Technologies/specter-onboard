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

# Create a systemd service

sudo cp ../systemd/camera-relay.service /etc/systemd/system/camera-relay.service

sudo systemctl daemon-reload
sudo systemctl enable camera-relay
sudo systemctl start camera-relay

echo "---Camera Stream Daemon Started---"
sudo systemctl status camera-relay
