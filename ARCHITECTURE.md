# Specter Onboard System - Architecture

## Overview

The onboard software stack runs on a Raspberry Pi 4 aboard the drone. It bridges the flight controller and camera to the ground control station (GCS) over a 5GHz WiFi link. The system is entirely shell-based — three systemd services, no application runtime.

---

## System Diagram

```
┌─────────────────────────────────────────────────────────┐
│                  Raspberry Pi 4 (Onboard)               │
│                                                         │
│  ┌──────────────┐   UART    ┌───────────────────────┐   │
│  │    Flight    │◄─────────►│   mavlink-router      │   │
│  │  Controller  │  115200   │   (mavlink-routerd)   │   │
│  └──────────────┘           └──────────┬────────────┘   │
│                                        │ UDP :14550     │
│  ┌──────────────┐   RTSP    ┌──────────▼────────────┐   │
│  │    Camera    │──────────►│   camera-relay        │   │
│  │  (Ethernet)  │           │   (GStreamer)          │   │
│  └──────────────┘           └──────────┬────────────┘   │
│                                        │ UDP :5600      │
│                             ┌──────────▼────────────┐   │
│                             │   drone-wifi          │   │
│                             │   (hostapd + dnsmasq) │   │
│                             │   wlan1: 192.168.10.1 │   │
└─────────────────────────────┴──────────┬────────────┘   
                                         │ 5GHz WiFi
                              ┌──────────▼────────────┐
                              │  Ground Control       │
                              │  Station (GCS)        │
                              │  192.168.10.110       │
                              │  QGroundControl       │
                              └───────────────────────┘
```

---

## Components

### drone-wifi (hostapd + dnsmasq)
Creates a 5GHz WiFi access point on `wlan1` (BL-M8812CU2 USB dongle). The RPi is the AP — the GCS connects to it, not the other way around. dnsmasq serves DHCP in the `192.168.10.0/24` range. The GCS is expected at `.110`.

**Why AP mode instead of client mode?** The drone doesn't rely on any external infrastructure. The GCS is always the one moving to the drone's network.

### mavlink-router
Reads MAVLink from the flight controller over UART and forwards to the GCS over UDP. Also exposes a TCP port for additional tools (e.g. Mission Planner). Handles reconnection automatically.

**Why mavlink-router instead of pymavlink?** Zero application code to maintain. mavlink-router is a proven C++ daemon — lightweight, battle-tested, handles multiplexing.

### camera-relay (GStreamer)
Pulls the H.265 RTSP stream from the camera over Ethernet, re-encapsulates as RTP/UDP, and sends to the GCS on port 5600. Two modes:

| Mode | `ENCODE_VIDEO` | What it does |
|------|----------------|--------------|
| Passthrough | `false` | Strip → repack RTP. ~2-3% CPU. |
| Transcode | `true` | Decode → scale/fps/bitrate → re-encode H.265. ~100% CPU — avoid without hardware encoder. |

### Link Manager _(not yet built)_
Will decide which physical link is active based on signal quality. Designed so adding a new link type (LoRa, LTE) requires a single registration — no changes to core routing logic.

Priority order: **5GHz WiFi → LoRa → 5G/LTE**

---

## Network Layout

| Interface | Address | Role |
|-----------|---------|------|
| `wlan1` | `192.168.10.1/24` | WiFi AP (air-ground link) |
| `eth0` | DHCP from camera | Camera RTSP source |

| Port | Protocol | Data |
|------|----------|------|
| `14550` | UDP | MAVLink (GCS) |
| `5760` | TCP | MAVLink (additional tools) |
| `5600` | UDP | Video RTP |

---

## Boot Sequence

```
Power on
  └─ systemd
       ├─ drone-wifi.service    → AP up on wlan1 at 192.168.10.1
       ├─ mavlink-router.service → MAVLink routing starts
       └─ camera-relay.service  → GStreamer pipeline starts
```

All services use `Restart=always`. A crashed service restarts within 3–5 seconds without affecting the others.

---

## Key Design Decisions

**Shell only, no Python daemon (yet)**
The current layer (routing + relay) has zero business logic — just pipe data between endpoints. Shell + proven daemons (mavlink-router, GStreamer) is the right call. Python (`pymavlink`) comes in when command interception or onboard decision-making is needed (Phase 2+).

**Env-file based config**
All tuneable values (IPs, ports, SSID, baud rate) live in `/etc/specter/*.env` files, sourced at runtime. No config is baked into scripts. This means changing GCS IP or video bitrate never requires touching code.

**Setup/runtime separation**
`setup_*.sh` scripts run once at install time. `*-start.sh` and `*-relay.sh` scripts are stateless runtime daemons called by systemd. Systemd can restart the runtime scripts freely without any side effects.

---

## What's Not Built Yet

- Link Manager + auto-failover logic
- LoRa fallback (Phase 3)
- 5G/LTE link (Phase 4)
- Python MAVLink daemon — command intercept/validation (Phase 2)
- Health check / watchdog script

## Open Questions

- Intercept and validate MAVLink commands on the RPi before forwarding to FC?
- Hardware H.265 encoder (`v4l2h265enc`) to enable transcode without CPU spike?
