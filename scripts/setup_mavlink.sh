#!/bin/bash
set -e

echo "--- Drone Onboard Setup ---"

# Install mavlink-router
sudo apt install -y git meson ninja-build pkg-config gcc g++ systemd systemd-dev
git clone https://github.com/mavlink-router/mavlink-router /tmp/mavlink-router
cd /tmp/mavlink-router
git submodule update --init --recursive
meson setup build . && ninja -C build
sudo ninja -C build install

# Copy config
sudo mkdir -p /etc/specter
sudo mkdir -p /etc/mavlink-router

sudo cp $SCRIPT_DIR/config/mavlink-router.env.template /etc/specter/mavlink-router.env
source /etc/specter/mavlink-router.env

export GCS_IP MAVLINK_PORT MAVLINK_TCP_PORT FC_DEVICE FC_BAUD

envsubst < $SCRIPT_DIR/config/mavlink-router.conf.template | \
  sudo tee /etc/mavlink-router/main.conf > /dev/null

# Install systemd service
sudo cp $SCRIPT_DIR/systemd/mavlink-router.service /etc/systemd/system/mavlink-router.service
sudo systemctl daemon-reload
sudo systemctl enable mavlink-router
sudo systemctl start mavlink-router

echo "--- Setup Complete ---"
echo "mavlink-router status:"
sudo systemctl status mavlink-router
