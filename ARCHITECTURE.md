# Specter Onboard System - Architecture

## What This Is
The onboard software stack running on linux based SBC (tested on raspberry pi 4) aboard the drone. Responsible for three things: bidirectional flow of MAVLink from the flight controller , managing the communication link to the ground, streaming video to the GCS.

---

## System Diagram

<img width="661" height="591" alt="image" src="https://github.com/user-attachments/assets/b24e1243-ba9d-4f78-8d6a-e9d0d2d7d0f9" />

## Components

### MAVLink Daemon
Bidirectional MAVLink router. Reads telemetry from FC and forwards to GCS. Receives commands from GCS and forwards to FC. Maintains single UART connection to FC and single network Connection to GCS over the active link.

### Link Manager
Decides which physical link is active based on signal quality and priority. Designed so adding a new link type (LoRa, LTE, 5G) in a single registration - no changes to core logic.

Priority order: 5GHz Wifi > LoRa > 5G/LTE

### Video Pipeline
GStreamer captures from the camera over RTSP protocol, encodes H.265 at 720p/30fps, streams RTP over UDP to GCS IP. Quality, framerate and Bitrate throttle automatically based on active link quality and capture mode.

---

## Key Decisions

**Why Python for the daemon?**
Fast iteration, strong MAVLink library (pymavlink)

## What's Not Built Yet
- Core modules
- LoRa fallback (Phase 3)
- 5G/LTE link (Phase 4)
- Automatic link failover logic


## Open Questions
- Do I implement a intercept and validate step in the RPi for the MAVLink commands
