#!/bin/bash
set -euo pipefail

echo "--- Health Logger Setup ---"

sudo mkdir -p /opt/specter/bin /etc/specter /var/log/specter

sudo cp "$SCRIPT_DIR"/scripts/health-logger.sh /opt/specter/bin/health-logger.sh
sudo chmod +x /opt/specter/bin/health-logger.sh

sudo cp "$SCRIPT_DIR"/config/health-logger.env.template /etc/specter/health-logger.env
sudo cp "$SCRIPT_DIR"/systemd/health-logger.service /etc/systemd/system/health-logger.service
sudo systemctl daemon-reload

# On-demand diagnostic: install but do NOT enable/start. Operator runs it for a test.
sudo systemctl disable health-logger 2>/dev/null || true

echo "--- Health Logger installed (run a test: sudo systemctl start health-logger) ---"
echo "health-logger: $(systemctl is-active health-logger)"
