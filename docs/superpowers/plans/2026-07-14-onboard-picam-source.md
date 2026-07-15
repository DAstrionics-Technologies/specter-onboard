# Onboard Pi-Camera Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CSI Pi-camera source mode to the `camera` module that streams hardware-H.264 to the GCS, so a Zero 2 W (no eth0) can send video.

**Architecture:** A `CAMERA_SOURCE=ip|picam` toggle in `camera-relay.env`. `camera-relay.sh` gets an early-exit `picam` branch (`libcamerasrc → v4l2h264enc → rtph264pay → udpsink`); `setup_camera.sh` conditionally installs libcamera deps and skips the eth0 static-IP step in picam mode.

**Tech Stack:** Bash, GStreamer, libcamera (`libcamerasrc`), `v4l2h264enc` (bcm2835 HW encoder), systemd, shellcheck. Target: Raspberry Pi Zero 2 W, Debian 13 RPi OS.

## Global Constraints

- **Default `CAMERA_SOURCE=ip`** — the existing IP-camera path stays byte-for-byte unchanged.
- **GCS-only** picam output in v1 (no cloud RTSP push).
- **Hardware H.264** via `v4l2h264enc` (Zero 2 W has no HW H.265 encode).
- **`rtph264pay config-interval=1`** hardcoded on the picam path (SPS/PPS repetition — correctness, not a knob).
- Picam reuses existing env params: `OUTPUT_WIDTH/HEIGHT/FPS/BITRATE`, `GCS_IP`, `VIDEO_PORT`, `PT`, `MTU`. `VIDEO_URL`/`CONFIG_INTERVAL` are IP-path-only.
- **Workflow:** the operator sets `CAMERA_SOURCE=picam` (+ `OUTPUT_*`) in `config/camera-relay.env.template` **before** running install (consistent with the README's "edit the config templates before running install").
- Branch: `feat/picam`, off `main`.
- No real unit-testable logic here (GStreamer pipelines) → verification is `shellcheck` + on-hardware (QGC video + `htop` CPU). No TDD test file.

---

### Task 1: `CAMERA_SOURCE` toggle + `camera-relay.sh` picam branch

**Files:**
- Modify: `config/camera-relay.env.template`
- Modify: `scripts/camera-relay.sh`

**Interfaces:**
- Produces: `camera-relay.sh`, when `CAMERA_SOURCE=picam`, streams hardware-H.264 RTP to
  `GCS_IP:VIDEO_PORT`; when `ip` (default), behaves exactly as today.

- [ ] **Step 1: Add the toggle to `config/camera-relay.env.template`**

Add near the top (after the `VIDEO_URL` line):
```ini
# Camera source: "ip" (RTSP IP camera, default) or "picam" (CSI Pi camera, hardware H.264).
# picam is for boards without ethernet (e.g. Zero 2 W). Set this before running install.
CAMERA_SOURCE=ip
```

- [ ] **Step 2: Add the picam branch to `scripts/camera-relay.sh`**

Immediately after the `source /etc/specter/camera-relay.env || { ... }` line and before the
`if [ "$ENCODE_VIDEO" = "true" ]; then` block, insert:
```bash
if [ "${CAMERA_SOURCE:-ip}" = "picam" ]; then
  # CSI Pi camera -> hardware H.264 -> RTP to GCS (Zero 2 W, no eth0 / no IP camera)
  exec gst-launch-1.0 \
    libcamerasrc ! \
    video/x-raw,width="${OUTPUT_WIDTH}",height="${OUTPUT_HEIGHT}",framerate="${OUTPUT_FPS}"/1 ! \
    videoconvert ! \
    v4l2h264enc extra-controls="controls,video_bitrate=$((OUTPUT_BITRATE*1000)),h264_i_frame_period=${OUTPUT_FPS}" ! \
    h264parse ! \
    rtph264pay config-interval=1 pt="${PT}" mtu="${MTU}" ! \
    udpsink host="${GCS_IP}" port="${VIDEO_PORT}" sync=false async=false
fi

```

- [ ] **Step 3: Verify syntax**

Run: `bash -n scripts/camera-relay.sh`
Expected: no output (syntax OK). `shellcheck` runs in CI.

- [ ] **Step 4: On-hardware smoke test** (Zero 2 W + CSI camera + laptop on the AP)

On the Pi, with a CSI camera connected:
```bash
sudo tee -a /etc/specter/camera-relay.env <<< 'CAMERA_SOURCE=picam'   # or edit the file
sudo /opt/specter/bin/camera-relay.sh &   # (or: sudo systemctl restart camera-relay)
```
- In QGroundControl: Video Settings → **UDP h.264 Video Stream**, port `5600` → **live video**.
- `htop` during the stream → `gst-launch`/`v4l2h264enc` at **single-digit % CPU** (hardware encode engaged). Video with CPU near 100% = software fallback = FAIL.
- Stop: `sudo pkill -f gst-launch` (or `systemctl stop camera-relay`).

- [ ] **Step 5: Commit**

```bash
git add config/camera-relay.env.template scripts/camera-relay.sh
git commit -m "feat: CSI Pi-camera source mode (hardware H.264 -> GCS)"
```

---

### Task 2: `setup_camera.sh` conditional install

**Files:**
- Modify: `scripts/setup_camera.sh`

**Interfaces:**
- Consumes: `CAMERA_SOURCE` from the copied `/etc/specter/camera-relay.env`.
- Produces: in picam mode, installs `gstreamer1.0-libcamera` + `rpicam-apps` and skips the
  eth0 static-IP step; in ip mode, unchanged.

- [ ] **Step 1: Branch the install on `CAMERA_SOURCE`**

In `scripts/setup_camera.sh`, after the line that copies the env template
(`sudo cp "$SCRIPT_DIR"/config/camera-relay.env.template /etc/specter/camera-relay.env`),
read the source and replace the existing `nmcli con add ... eth0` block with a branch:
```bash
# shellcheck source=/dev/null
source /etc/specter/camera-relay.env

if [ "${CAMERA_SOURCE:-ip}" = "picam" ]; then
  # CSI Pi camera: libcamera GStreamer plugin + camera detection. No eth0.
  sudo apt install -y gstreamer1.0-libcamera rpicam-apps
  rpicam-hello --list-cameras || echo "WARNING: no CSI camera detected — check the ribbon cable."
else
  # IP camera: static IP on the camera Ethernet interface.
  if ! nmcli con show camera &>/dev/null; then
    nmcli con add type ethernet con-name camera ifname eth0 \
      ipv4.addresses 192.168.144.1/24 ipv4.method manual || true
  fi
fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/setup_camera.sh`
Expected: no output. `shellcheck` runs in CI.

- [ ] **Step 3: On-hardware acceptance** (Zero 2 W + CSI camera)

```bash
# edit the template first: set CAMERA_SOURCE=picam (+ OUTPUT_* e.g. 1280x720@15, 2000 kbps)
./install.sh --profile full            # or a profile that includes camera
```
Expected: `setup_camera` installs `gstreamer1.0-libcamera`, `rpicam-hello --list-cameras`
lists the sensor, skips the eth0 nmcli step, and the install summary shows `camera OK active`.
Then confirm QGC shows live H.264 video (as in Task 1 Step 4) and CPU stays low.

- [ ] **Step 4: Commit**

```bash
git add scripts/setup_camera.sh
git commit -m "feat: setup_camera installs libcamera + skips eth0 in picam mode"
```

---

## Final verification (before PR)

- [ ] `shellcheck scripts/camera-relay.sh scripts/setup_camera.sh` clean in CI.
- [ ] `bash -n` clean on both.
- [ ] With `CAMERA_SOURCE=ip` (default), IP-camera path unchanged (no regression).
- [ ] With `CAMERA_SOURCE=picam` on a Zero 2 W + CSI camera: QGC shows live H.264 video on
      `5600`, and `htop` confirms hardware encode (low CPU).
- [ ] `setup_camera --profile ...` in picam mode installs libcamera deps and skips eth0.
