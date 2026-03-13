#!bin/bash

# Installing GStreamer
sudo apt install -y \
  gstreamer1.0-tools \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-libav

# Create a systemd service

sudo cp -r ../systemd/camera-relay.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable camera-relay
sudo systemctl start camera-relay
