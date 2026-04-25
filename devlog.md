## 2026-04-25 — API key auth client + MAVLink sentinel handling

- Wired `DRONE_API_KEY` into telemetry sender. Set as default `X-API-Key` header on the `httpx.Client` so every POST carries it automatically.
- Fail-loud at startup if `DRONE_API_KEY` is unset — `sys.exit(1)` so systemd's restart loop becomes the visible signal. A misconfigured drone should not silently 401-spam the cloud.
- 401 handling: separate `auth_fail_count` from the existing transport `fail_count`. Different root causes deserve different signals — auth failures don't trigger "Cloud connection lost" anymore.
- Capped exponential backoff on 401 (`1s, 2s, 4s, ..., 60s` cap). Avoids 1Hz log spam during a revoked-key scenario. Drone keeps retrying forever; on first 200 response, counters and backoff window reset and normal cadence resumes.
- `BYPASS_GPS_GATE=1` env override seeds dummy coords for dev rigs without a GPS lock. Production behavior unchanged.
- MAVLink sentinel translation in `update_state` for `SYS_STATUS`: skip the assignment when `battery_remaining == -1` or `voltage_battery == 65535` (UINT16_MAX). Both are "field not provided" sentinels per the spec; without filtering, a bare FC's first packet would propagate `-1%` battery and `65.5V` voltage to the cloud and 422.
- Setup script: `chmod 600 root:root` on the env file (now contains a secret). Setup script no longer auto-starts `telemetry-sender.service` if `DRONE_API_KEY` is empty — prevents a guaranteed flap.

## devlog.md - baseline measurements

- Boot to first heartbeat: 62-65s
- Mavlink latency: ?ms
- Video latency (eyeball): 30ms
- CPU usage while streaming: 6-10%
- RAM usage while streaming: 2-3

## 2026-04-08
- Built telemetry sender — Python script that reads MAVLink from mavlink-router (TCP :5760), accumulates state, POSTs to specter-cloud at 1Hz
  - Accumulator pattern: HEARTBEAT, GLOBAL_POSITION_INT, SYS_STATUS, VFR_HUD, GPS_RAW_INT → single payload
  - Requests data streams itself via `request_data_stream_send` — works independently of QGC
  - Error handling: network/timeout failures don't crash the MAVLink loop, logs recovery after cloud reconnect
  - Event-driven logging: armed/disarmed transitions, flight mode changes, GPS fix acquired, cloud connection lost/restored
  - Used `logging` stdlib (not structlog) — appropriate for single-purpose onboard script, maps to journald priorities
- Switched to uv for Python dependency management
  - `pyproject.toml` + `uv.lock` for reproducible installs across fleet
  - `uv sync --no-dev` on RPi, `uv run pytest` for dev
- Created systemd service for telemetry sender
  - `Requires=mavlink-router.service` — stops if mavlink-router dies, restarts when it comes back
  - `EnvironmentFile=/etc/specter/telemetry-sender.env` — config without shell wrapper
- Added unit tests for update_state (MAVLink conversions) and build_payload
  - FakeMsg pattern instead of pymavlink mocks — tests the logic, not the library
  - Skipped HEARTBEAT flight mode test — depends on pymavlink internals (mode_string_v10)
- Cloud video relay working end-to-end
  - Separate GStreamer pipeline for cloud (RTSP push via rtspclientsink to mediamtx)
  - Independent of GCS pipeline — cloud failure doesn't kill GCS video
  - Camera needs static IP on eth0 (192.168.144.1) via NetworkManager
- Updated README with telemetry sender, cloud streaming, uv setup, dev section

### Issues found and fixed
- `heading` double conversion — `math.degrees(msg.hdg / 100)` was converting degrees→degrees. Fix: just `msg.hdg / 100`
- ATTITUDE values divided by 1e7 — they're already radians as floats, not scaled ints
- `recv_match(type=[...])` whitelist was missing VFR_HUD and GPS_RAW_INT — those messages silently dropped
- `request_data_stream_send` before `wait_heartbeat` — target_system is 0 until heartbeat arrives
- `SEND_INTERVAL` from env was string, compared with `>=` against float — wrapped in `int()`
- KeyError on first send — state dict had no defaults, first POST fired before any messages arrived
- `async def send()` called without await from sync `run()` — coroutine never executed. Fix: keep everything sync

### Metrics
- Telemetry sender CPU: ~1% (pymavlink + httpx at 1Hz)
- Cloud video relay CPU: ~6% (separate GStreamer pipeline)
- End-to-end telemetry latency: <1s (MAVLink → RPi → cloud API → DB)

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

