#!/bin/bash
# health-check.sh — run on the RPi to verify all onboard systems are working.
# Usage: bash tests/health-check.sh

PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC}  $1"; ((FAIL++)); }
# shellcheck disable=SC2317  # helper kept for future checks; not called yet
info() { echo -e "  ${YELLOW}i${NC}  $1"; }

echo ""
echo "=== Specter Onboard Health Check ==="
echo ""

# ── 1. Services ───────────────────────────────────────────────────────────────
echo "── Services ──"

for svc in drone-wifi mavlink-router camera-relay; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc is running"
    else
        fail "$svc is NOT running (sudo systemctl status $svc)"
    fi
done
echo ""

# ── 2. WiFi AP ────────────────────────────────────────────────────────────────
echo "── WiFi AP ──"

WIFI_ENV="/etc/specter/wifi.env"
IFACE="wlan1"
EXPECTED_IP="192.168.10.1"

[ -f "$WIFI_ENV" ] && source "$WIFI_ENV" && IFACE="${WIFI_INTERFACE:-wlan1}"

if ip link show "$IFACE" &>/dev/null; then
    ok "Interface $IFACE exists"
else
    fail "Interface $IFACE not found"
fi

ACTUAL_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1)
if [ "$ACTUAL_IP" = "$EXPECTED_IP" ]; then
    ok "$IFACE has IP $EXPECTED_IP"
else
    fail "$IFACE IP is '${ACTUAL_IP:-none}', expected $EXPECTED_IP"
fi

if pgrep -x hostapd &>/dev/null; then
    ok "hostapd process is running"
else
    fail "hostapd process not found"
fi

if pgrep -x dnsmasq &>/dev/null; then
    ok "dnsmasq process is running"
else
    fail "dnsmasq process not found"
fi
echo ""

# ── 3. MAVLink ────────────────────────────────────────────────────────────────
echo "── MAVLink ──"

MAV_ENV="/etc/specter/mavlink-router.env"
FC_DEVICE="/dev/ttyACM0"
MAV_PORT=14550

[ -f "$MAV_ENV" ] && source "$MAV_ENV" && FC_DEVICE="${FC_DEVICE:-/dev/ttyACM0}" MAV_PORT="${MAVLINK_PORT:-14550}"

if [ -e "$FC_DEVICE" ]; then
    ok "FC device $FC_DEVICE is present"
else
    fail "FC device $FC_DEVICE not found (flight controller connected?)"
fi

if ss -ulpn 2>/dev/null | grep -q ":$MAV_PORT"; then
    ok "mavlink-router listening on UDP :$MAV_PORT"
else
    fail "Nothing listening on UDP :$MAV_PORT"
fi
echo ""

# ── 4. Camera ─────────────────────────────────────────────────────────────────
echo "── Camera ──"

CAM_ENV="/etc/specter/camera-relay.env"
VIDEO_URL="rtsp://192.168.144.25:8554/main.264"

[ -f "$CAM_ENV" ] && source "$CAM_ENV"

# Check GStreamer pipeline is running
if pgrep -f "gst-launch" &>/dev/null; then
    ok "GStreamer pipeline is running"
else
    fail "GStreamer pipeline not found"
fi

# Check camera host is reachable
CAM_HOST=$(echo "$VIDEO_URL" | sed 's|rtsp://||' | cut -d':' -f1)
if ping -c 1 -W 2 "$CAM_HOST" &>/dev/null; then
    ok "Camera host $CAM_HOST is reachable"
else
    fail "Camera host $CAM_HOST is unreachable (Ethernet connected?)"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "── Summary ──"
TOTAL=$((PASS + FAIL))
echo -e "  Passed: ${GREEN}$PASS${NC} / $TOTAL"
if [ "$FAIL" -gt 0 ]; then
    echo -e "  Failed: ${RED}$FAIL${NC} / $TOTAL"
    echo ""
    echo "  Run 'sudo journalctl -fu <service>' to inspect a failing service."
    exit 1
else
    echo -e "  ${GREEN}All checks passed.${NC}"
    exit 0
fi
