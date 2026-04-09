#!/bin/bash
set -e

# Get directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

echo "--- Running Setup Scripts ---"

# Run them
sudo env SCRIPT_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/setup_wifi.sh"
sudo env SCRIPT_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/setup_mavlink.sh"
sudo env SCRIPT_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/setup_camera.sh"
sudo env SCRIPT_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/setup_telemetry.sh"

echo "--- Setup Complete ---"