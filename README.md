# Project Specter — Onboard

Onboard software stack for the Specter drone, running on a Raspberry Pi 4. Handles three jobs:

- **MAVLink routing** — bidirectional FC ↔ GCS telemetry over UDP
- **Video streaming** — H.265 RTSP relay to GCS via GStreamer
- **WiFi AP** — 5GHz access point so the GCS can connect to the drone


---

## Overview

```
Flight Controller ──UART──► RPi 4 ──UDP:14550──► GCS (QGroundControl)
Camera ───────────RTSP──►  (wlan1 AP)──UDP:5600──► GCS video
                           192.168.10.1
```

The RPi is the access point — the GCS connects to it. Three systemd services start on boot and restart automatically on crash. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design breakdown.

---

## Hardware


| Port | Device | Notes |
|------|--------|-------|
| UART `/dev/ttyAMA0` or USB | Flight Controller | TX→RX, RX→TX, GND |
| USB (`wlan1`) | BL-M8812CU2 WiFi Module | 5GHz air-ground link |
| CSI / USB / Ethernet | Camera | RTSP source |
| 5V / 3A | Power | BEC from drone power system |

---

## Quick Start

### 1. Flash OS

Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. In imager settings:
- Enable SSH
- Set username: `da`
- Set a password
- Configure WiFi (temporary, for initial setup only)

### 2. First Boot

```bash
ssh da@raspberrypi.local

# Update system
sudo apt update && sudo apt upgrade -y

# Enable UART for flight controller
sudo raspi-config
# Interface Options → Serial Port → Login shell: No → Hardware: Yes

sudo reboot
```

### 3. Clone and Configure

```bash
git clone https://github.com/DAstrionics-Technologies/specter-onboard
cd specter-onboard
```

Edit the config templates before running install:

| File | What to configure |
|------|-------------------|
| `config/wifi.env.template` | AP SSID, password, channel, interface |
| `config/mavlink-router.env.template` | GCS IP, MAVLink ports, FC device + baud |
| `config/camera-relay.env.template` | Camera RTSP URL, GCS IP, video port |

### 4. Install

```bash
chmod +x install.sh && ./install.sh
```

This runs three setup scripts in order:

1. `setup_wifi.sh` — installs hostapd/dnsmasq, generates `hostapd.conf`, enables `drone-wifi.service`
2. `setup_mavlink.sh` — builds mavlink-router from source, enables `mavlink-router.service`
3. `setup_camera.sh` — installs GStreamer, deploys camera relay, enables `camera-relay.service`

On next boot, all three services start automatically.

---

## Services

| Service | Script | Description |
|---------|--------|-------------|
| `drone-wifi.service` | `wifi-start.sh` | Brings up 5GHz AP on `wlan1` at `192.168.10.1` |
| `mavlink-router.service` | `mavlink-routerd` | Routes MAVLink: UART FC ↔ UDP GCS |
| `camera-relay.service` | `camera-relay.sh` | GStreamer RTSP relay over UDP to GCS |

All services use `Restart=always` and start on boot via `multi-user.target`.

---

## Network Layout

```
Drone (RPi AP)                         GCS
192.168.10.1  ←── 5GHz WiFi ───→  192.168.10.110
              MAVLink UDP :14550
              MAVLink TCP :5760
              Video   UDP :5600
```

DHCP serves `192.168.10.50–150`. The GCS is expected at `.110` (set in env templates).

---

## Configuration Reference

### `config/wifi.env.template`
```ini
WIFI_INTERFACE=wlan1
WIFI_SSID=Specter-Drone
WIFI_PASSWORD=changeme123
WIFI_CHANNEL=36
```

### `config/mavlink-router.env.template`
```ini
GCS_IP=192.168.10.110
MAVLINK_PORT=14550
MAVLINK_TCP_PORT=5760
FC_DEVICE=/dev/ttyACM0
FC_BAUD=115200
```

### `config/camera-relay.env.template`
```ini
VIDEO_URL=rtsp://192.168.144.25:8554/main.264
GCS_IP=192.168.10.110
VIDEO_PORT=5600
ENCODE_VIDEO=false   # set true to enable transcoding
OUTPUT_WIDTH=1280
OUTPUT_HEIGHT=720
OUTPUT_FPS=15
OUTPUT_BITRATE=2000
```

---

## Repo Structure

```
specter-onboard/
├── install.sh              # Entry point — runs all setup scripts
├── config/                 # Config templates (copied to /etc/specter/ at install)
│   ├── wifi.env.template
│   ├── hostapd.conf.template
│   ├── mavlink-router.env.template
│   ├── mavlink-router.conf.template
│   └── camera-relay.env.template
├── scripts/
│   ├── setup_wifi.sh       # One-time WiFi AP setup
│   ├── wifi-start.sh       # Runtime AP daemon (called by systemd)
│   ├── setup_mavlink.sh    # One-time mavlink-router build + setup
│   ├── setup_camera.sh     # One-time GStreamer + camera-relay setup
│   └── camera-relay.sh     # Runtime GStreamer pipeline (called by systemd)
├── systemd/                # Service unit files
│   ├── drone-wifi.service
│   ├── mavlink-router.service
│   └── camera-relay.service
└── src/                    # Python daemon (planned)
```

---

## Roadmap

- [ ] Python MAVLink daemon (`pymavlink`) — core modules
- [ ] Link Manager — auto-failover between 5GHz WiFi → LoRa → 5G/LTE
- [ ] LoRa fallback link (Phase 3)
- [ ] 5G/LTE link (Phase 4)
