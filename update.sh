#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for what this drone is (written by install.sh).
PROFILE="$(cat /etc/specter/installed-profile 2>/dev/null || echo full)"
PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE.conf"
has_module() { [ -f "$PROFILE_FILE" ] && grep -qxF "$1" <(sed 's/#.*//; s/[[:space:]]//g' "$PROFILE_FILE"); }

echo "--- Updating Specter Onboard (profile: $PROFILE) ---"

if has_module wifi; then
  sudo cp "$SCRIPT_DIR/scripts/wifi-start.sh" /opt/specter/bin/wifi-start.sh
  sudo chmod +x /opt/specter/bin/wifi-start.sh
  sudo cp "$SCRIPT_DIR/systemd/drone-wifi.service" /etc/systemd/system/drone-wifi.service
fi

if has_module mavlink; then
  if [ -x "$SCRIPT_DIR/bin/mavlink-routerd" ]; then
    sudo install -m 755 "$SCRIPT_DIR/bin/mavlink-routerd" /usr/bin/mavlink-routerd
  fi
  sudo cp "$SCRIPT_DIR/systemd/mavlink-router.service" /etc/systemd/system/mavlink-router.service
  # shellcheck source=/dev/null
  source /etc/specter/mavlink-router.env
  export GCS_IP MAVLINK_PORT MAVLINK_TCP_PORT FC_DEVICE FC_BAUD
  envsubst < "$SCRIPT_DIR/config/mavlink-router.conf.template" | \
    sudo tee /etc/mavlink-router/main.conf > /dev/null
fi

if has_module camera; then
  sudo cp "$SCRIPT_DIR/scripts/camera-relay.sh" /opt/specter/bin/camera-relay.sh
  sudo chmod +x /opt/specter/bin/camera-relay.sh
  sudo cp "$SCRIPT_DIR/systemd/camera-relay.service" /etc/systemd/system/camera-relay.service
fi

if has_module telemetry; then
  sudo cp "$SCRIPT_DIR/src/telemetry_sender.py" /opt/specter/src/telemetry_sender.py
  sudo cp "$SCRIPT_DIR/systemd/telemetry-sender.service" /etc/systemd/system/telemetry-sender.service
  # Install vendored wheels if present (offline dep updates)
  if [ -d "$SCRIPT_DIR/wheels" ]; then
    echo "Installing vendored dependencies..."
    (cd /opt/specter && sudo uv pip install --find-links "$SCRIPT_DIR/wheels/" --offline pymavlink httpx)
  fi
fi

sudo systemctl daemon-reload

# Restart only installed services (non-fatal — hardware may be absent)
if has_module camera;    then sudo systemctl restart camera-relay    || true; fi
if has_module telemetry; then sudo systemctl restart telemetry-sender || true; fi
if has_module mavlink;   then sudo systemctl restart mavlink-router   || true; fi

echo "--- Update Complete (profile: $PROFILE) ---"
if has_module wifi;      then echo "drone-wifi:        $(systemctl is-active drone-wifi)"; fi
if has_module mavlink;   then echo "mavlink-router:    $(systemctl is-active mavlink-router)"; fi
if has_module camera;    then echo "camera-relay:      $(systemctl is-active camera-relay)"; fi
if has_module telemetry; then echo "telemetry-sender:  $(systemctl is-active telemetry-sender)"; fi
