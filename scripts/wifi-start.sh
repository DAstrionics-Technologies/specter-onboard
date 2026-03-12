#!/bin/bash
# Wait for wlan1 to exist
for i in $(seq 1 30); do
    if ip link show wlan1 &>/dev/null; then
        break
    fi
    sleep 1
done

# Stop conflicting services
wpa_cli -i wlan1 terminate 2>/dev/null
nmcli dev set wlan1 managed no 2>/dev/null

# Assign IP
ip addr flush dev wlan1
ip addr add 192.168.10.1/24 dev wlan1
ip link set wlan1 up

# Start hostapd
hostapd /etc/hostapd/hostapd.conf &
HOSTAPD_PID=$!
sleep 2

# Start dnsmasq bound to wlan1
dnsmasq --interface=wlan1 --bind-interfaces \
    --dhcp-range=192.168.10.50,192.168.10.150,255.255.255.0,24h \
    --no-daemon &
DNSMASQ_PID=$!

# Wait for either to exit
wait -n $HOSTAPD_PID $DNSMASQ_PID

# If one dies, kill the other
kill $HOSTAPD_PID $DNSMASQ_PID 2>/dev/null
