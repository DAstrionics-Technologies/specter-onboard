#!/bin/bash
set -e

echo "---Installing Telemetry Sender---"

# Install uv system-wide if not present
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  sudo mv /root/.local/bin/uv /usr/local/bin/uv
fi

# Copy project files to /opt/specter/
sudo mkdir -p /opt/specter/src
sudo cp $SCRIPT_DIR/pyproject.toml /opt/specter/pyproject.toml
sudo cp $SCRIPT_DIR/uv.lock /opt/specter/uv.lock
sudo cp $SCRIPT_DIR/src/telemetry_sender.py /opt/specter/src/telemetry_sender.py

# Sync dependencies from lockfile
cd /opt/specter && sudo uv sync --no-dev

# Copy env config (env file holds DRONE_API_KEY, lock it down to root)
sudo mkdir -p /etc/specter
sudo cp $SCRIPT_DIR/config/telemetry-sender.env.template /etc/specter/telemetry-sender.env
sudo chown root:root /etc/specter/telemetry-sender.env
sudo chmod 600 /etc/specter/telemetry-sender.env

# Install systemd service
sudo cp $SCRIPT_DIR/systemd/telemetry-sender.service /etc/systemd/system/telemetry-sender.service

sudo systemctl daemon-reload
sudo systemctl enable telemetry-sender

# Don't auto-start if DRONE_API_KEY is unset — service would just flap.
if sudo grep -q "^DRONE_API_KEY=$" /etc/specter/telemetry-sender.env; then
    echo ""
    echo "DRONE_API_KEY is empty in /etc/specter/telemetry-sender.env"
    echo "Mint a key on the cloud (scripts/mint_key.py) and add it to the file."
    echo "Then start the service: sudo systemctl start telemetry-sender"
else
    sudo systemctl start telemetry-sender
    echo "---Telemetry Sender Started---"
    sudo systemctl status telemetry-sender
fi
