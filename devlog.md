## devlog.md - baseline measurements

- Boot to first heartbeat: ?ms
- Mavlink latency: ?ms
- Video latency (eyeball): ?ms
- CPU usage while streaming: ?
- RAM usage while streaming: ?

## 2026-03-14

**Phase 0-1 essentially complete.**

### What's working
- MAVLink forwarding via mavlink-router — auto-connect, auto-reconnect
- Video streaming via GStreamer — auto-connect, auto-reconnect
- Full systemd service management — both services survive reboot/crash
- Single install script — fresh RPi to working system
- CPU at 2-3% idle streaming — no encode, pure forwarding

### Architecture
Shell only. No Python. Two systemd services + config env files.
This is the correct approach for this layer.

### Issues found and fixed
- [write the bumps you hit and how you fixed them — these are interview stories]

### Known issue
- Video resolution drops at higher res — encoding disabled (100% CPU spike)
- Fix: reduce source resolution in video.env, revisit with hardware encoder

### Metrics
- CPU usage: 2-3%
- Boot to MAVLink connect: ?s
- Video latency: 20ms approx

### Remaining for v1.0.0
- WiFi setup script (hostapd + cu2)
- Health check script
- README logging section


## 2026-03-13
- Mavlink and video stream is working
- Reconnection logic is working
- automatic connection is working


## 2026-03-12
- Created .gitattributes file with eol=lf (windows file ending)
- Fixed systemd package not found while building mavlink-router
- Created script to automate dnsmasq setup


## 2026-03-11
- Created the structure of the repo
- Set up mavlink router - forwading mavlink from fc to gcs over udp (static ip)
- Created script for 1 time setup of RPi
- Created systemd service for malink router autostart
- Created config file for mavlink router


## 2026-03-10
- Created the repo
- Created org and moved the repo in the org

