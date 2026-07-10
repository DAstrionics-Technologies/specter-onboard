#!/bin/bash
set -e

echo "--- Drone Onboard Setup ---"

# Install mavlink-router: prefer the committed prebuilt binary; build only as fallback.
if [ -x "$SCRIPT_DIR/bin/mavlink-routerd" ]; then
  echo "Installing prebuilt mavlink-routerd..."
  sudo install -m 755 "$SCRIPT_DIR/bin/mavlink-routerd" /usr/bin/mavlink-routerd
elif ! command -v mavlink-routerd &>/dev/null; then
  echo "No prebuilt binary found — building from source (slow on low-RAM boards)..."
  bash "$SCRIPT_DIR/scripts/build_mavlink_router.sh" --install
fi

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
sudo systemctl start mavlink-router || true

echo "--- Setup Complete ---"
echo "mavlink-router: $(systemctl is-active mavlink-router)"
