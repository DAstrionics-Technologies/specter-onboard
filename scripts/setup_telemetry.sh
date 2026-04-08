#!/bin/bash
set -e

echo "---Installing Telemetry Sender---"

# Install uv if not present
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# Create project directory and sync dependencies from lockfile
sudo mkdir -p /opt/specter/src
sudo cp $SCRIPT_DIR/pyproject.toml /opt/specter/pyproject.toml
sudo cp $SCRIPT_DIR/uv.lock /opt/specter/uv.lock
cd /opt/specter && sudo uv sync --no-dev

# Copy script
sudo cp $SCRIPT_DIR/src/telemetry_sender.py /opt/specter/src/telemetry_sender.py

# Copy env config
sudo mkdir -p /etc/specter
sudo cp $SCRIPT_DIR/config/telemetry-sender.env.template /etc/specter/telemetry-sender.env

# Install systemd service
sudo cp $SCRIPT_DIR/systemd/telemetry-sender.service /etc/systemd/system/telemetry-sender.service

sudo systemctl daemon-reload
sudo systemctl enable telemetry-sender
sudo systemctl start telemetry-sender

echo "---Telemetry Sender Started---"
sudo systemctl status telemetry-sender
