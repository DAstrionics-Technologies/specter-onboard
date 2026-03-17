## devlog.md - baseline measurements

- Boot to first heartbeat: 62-65s
- Mavlink latency: ?ms
- Video latency (eyeball): 30ms
- CPU usage while streaming: 6-10%
- RAM usage while streaming: 2-3

## 2026-03-17
- Fixed WiFi AP setup — was broken out of the box on a fresh RPi
  - Added missing `hostapd.conf.template` and `wifi.env.template`
  - Split `wifi-start.sh` into `setup_wifi.sh` (one-time install) and `wifi-start.sh` (runtime daemon)
  - Added `rfkill unblock wifi` to handle soft-blocked radio on RPi OS
  - Set `DAEMON_CONF` in `/etc/default/hostapd` to unmask hostapd
  - Fixed `sudo env SCRIPT_DIR=...` bug — `sudo bash` strips exported vars
- Rewrote README with full sections
- Tested full install on fresh RPi — AP up, MAVLink routing, video relay all working


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
- `sudo bash` drops exported variables — `SCRIPT_DIR` arrived empty inside setup scripts, breaking all file copy paths. Fixed with `sudo env SCRIPT_DIR=... bash`
- hostapd ships masked on RPi OS — must set `DAEMON_CONF` in `/etc/default/hostapd` to unmask it
- wlan1 (USB dongle) takes a few seconds to enumerate after boot — added a 30s polling loop before bringing the interface up
- setup and runtime logic were mixed in `wifi-start.sh` — systemd restarts re-ran `apt install` on every crash. Separated into `setup_wifi.sh` (one-time) and `wifi-start.sh` (runtime)

### Known issue
- Video resolution drops at higher res — encoding disabled (100% CPU spike)
- Fix: reduce source resolution in video.env, revisit with hardware encoder

### Metrics
- CPU usage: 2-3%
- Boot to MAVLink connect: ?s
- Video latency: 20ms approx

### Remaining for v1.0.0
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

