#!/bin/bash
set -e

# Get directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

echo "--- Running Setup Scripts ---"

# Run them
sudo bash "$SCRIPT_DIR/scripts/wifi-start.sh"
sudo bash "$SCRIPT_DIR/scripts/setup_mavlink.sh"
sudo bash "$SCRIPT_DIR/scripts/setup_camera.sh"

echo "--- Setup Complete ---"