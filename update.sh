#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Updating Specter Onboard ---"

# Update scripts
sudo cp $SCRIPT_DIR/scripts/camera-relay.sh /opt/specter/bin/camera-relay.sh
sudo chmod +x /opt/specter/bin/camera-relay.sh

# Update telemetry sender
sudo cp $SCRIPT_DIR/src/telemetry_sender.py /opt/specter/src/telemetry_sender.py

# Update systemd services
sudo cp $SCRIPT_DIR/systemd/camera-relay.service /etc/systemd/system/camera-relay.service
sudo cp $SCRIPT_DIR/systemd/mavlink-router.service /etc/systemd/system/mavlink-router.service
sudo cp $SCRIPT_DIR/systemd/telemetry-sender.service /etc/systemd/system/telemetry-sender.service
sudo cp $SCRIPT_DIR/systemd/drone-wifi.service /etc/systemd/system/drone-wifi.service
sudo systemctl daemon-reload

# Update mavlink-router config if env changed
if [ -f $SCRIPT_DIR/config/mavlink-router.env.template ]; then
  source /etc/specter/mavlink-router.env
  export GCS_IP MAVLINK_PORT MAVLINK_TCP_PORT FC_DEVICE FC_BAUD
  envsubst < $SCRIPT_DIR/config/mavlink-router.conf.template | \
    sudo tee /etc/mavlink-router/main.conf > /dev/null
fi

# Install vendored wheels if present (for offline dep updates)
if [ -d $SCRIPT_DIR/wheels ]; then
  echo "Installing vendored dependencies..."
  cd /opt/specter && sudo uv pip install --find-links $SCRIPT_DIR/wheels/ --offline pymavlink httpx
fi

# Restart services
sudo systemctl restart camera-relay
sudo systemctl restart telemetry-sender

echo "--- Update Complete ---"
echo "camera-relay:      $(systemctl is-active camera-relay)"
echo "telemetry-sender:  $(systemctl is-active telemetry-sender)"
echo "mavlink-router:    $(systemctl is-active mavlink-router)"
echo "drone-wifi:        $(systemctl is-active drone-wifi)"
