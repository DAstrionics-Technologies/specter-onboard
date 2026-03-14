#!/bin/bash
set -e

# Get directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Running Setup Scripts ---"

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR/scripts/wifi-start.sh"
chmod +x "$SCRIPT_DIR/scripts/setup_mavlink.sh"
chmod +x "$SCRIPT_DIR/scripts/setup_camera.sh"

# Run them
sudo bash "$SCRIPT_DIR/scripts/wifi-start.sh"
sudo bash "$SCRIPT_DIR/scripts/setup_mavlink.sh"
sudo bash "$SCRIPT_DIR/scripts/setup_camera.sh"

echo "--- Setup Complete ---"