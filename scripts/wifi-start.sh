#!/bin/bash
# Runtime script — called by drone-wifi.service on every boot.
# Does NOT install packages or copy files; that is setup_wifi.sh's job.

set -e
source /etc/specter/wifi.env || { echo "ERROR: wifi.env not found" >&2; exit 1; }

IFACE="${WIFI_INTERFACE:-wlan1}"
AP_IP="${WIFI_IP}"

echo "--- Starting Drone WiFi AP on $IFACE ---"

# Unblock any software RF kill
rfkill unblock wifi

# Wait for the interface to appear (USB dongle may take a moment)
for i in $(seq 1 30); do
    ip link show "$IFACE" &>/dev/null && break
    echo "Waiting for $IFACE... ($i/30)"
    sleep 1
done

if ! ip link show "$IFACE" &>/dev/null; then
    echo "ERROR: $IFACE never appeared. Aborting." >&2
    exit 1
fi

# Release interface from NetworkManager / wpa_supplicant
wpa_cli -i "$IFACE" terminate 2>/dev/null || true
nmcli dev set "$IFACE" managed no 2>/dev/null || true

# Assign static IP
ip addr flush dev "$IFACE"
ip addr add "$AP_IP/24" dev "$IFACE"
ip link set "$IFACE" up

# Start hostapd (foreground so systemd tracks the PID)
hostapd /etc/hostapd/hostapd.conf &
HOSTAPD_PID=$!
sleep 2

# Start dnsmasq bound to the interface
dnsmasq --interface="$IFACE" --bind-interfaces \
    --dhcp-range=${WIFI_IP_RANGE},255.255.255.0,24h \
    --no-daemon &
DNSMASQ_PID=$!

# Wait for either process to exit, then kill the other
wait -n $HOSTAPD_PID $DNSMASQ_PID
kill $HOSTAPD_PID $DNSMASQ_PID 2>/dev/null || true
