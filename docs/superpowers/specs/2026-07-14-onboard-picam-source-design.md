# Onboard Pi-Camera Source — Design

**Date:** 2026-07-14
**Status:** Approved (design), pending implementation plan
**Repo:** specter-onboard
**Branch:** `feat/picam` (off `main`; independent of `feat/health-logger`)

## Problem

The `camera` module streams from an **IP camera** (`rtspsrc rtsp://192.168.144.25`,
H.265) reachable over `eth0`. The Raspberry Pi Zero 2 W has **no ethernet port**, so
that path is unusable there — a Zero 2 W drone can't stream video with the current
stack. Separately, the software-H.265 transcode branch pegs the Zero 2 W CPU at ~100%.

## Goal

Let the `camera` module capture from a **CSI Pi Camera** and stream to the GCS using
the Zero 2 W's **hardware H.264 encoder**, so a Zero 2 W drone gets low-CPU video with
no ethernet and no IP camera.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Camera hardware | **CSI ribbon Pi Camera** (v2/v3/HQ) | Roadmap path; enables the hardware encoder. |
| Encode | **Hardware H.264** (`v4l2h264enc`) | Zero 2 W has HW H.264 (no HW H.265); ~single-digit % CPU. |
| Output paths (v1) | **GCS only** (RTP/UDP to `VIDEO_PORT`) | One pipeline, one failure mode; matches first-flight testing. |
| Integration | **Source toggle in the existing `camera` module** (`CAMERA_SOURCE=ip\|picam`) | Reuses config/service/module; matches existing `ENCODE_VIDEO`/`CLOUD_STREAM` toggles. |

## Non-goals (YAGNI)

- No cloud RTSP push on the picam path in v1 (reuse `CLOUD_STREAM` pattern later).
- No new `picam` module (rejected — duplicates plumbing; a drone uses exactly one camera).
- No change to the IP-camera path (default `CAMERA_SOURCE=ip` keeps it byte-for-byte).
- No transcode/scaling stage on picam (capture at target `OUTPUT_*` directly).

## Architecture

### 1. Config toggle

Add to `config/camera-relay.env.template`:
```ini
# Camera source: "ip" (RTSP IP camera, default) or "picam" (CSI Pi camera, hardware H.264)
CAMERA_SOURCE=ip
```
The picam path **reuses existing params** — no new video knobs:
- `OUTPUT_WIDTH` / `OUTPUT_HEIGHT` / `OUTPUT_FPS` / `OUTPUT_BITRATE` — capture + encode spec.
- `GCS_IP` / `VIDEO_PORT` / `PT` / `MTU` / `CONFIG_INTERVAL` — RTP/UDP output (same as IP path).

`VIDEO_URL` (IP camera) is unused in picam mode. `CONFIG_INTERVAL` stays an IP-path
param; the picam pipeline **hardcodes** `rtph264pay config-interval=1` — periodic SPS/PPS
is a correctness requirement for H.264 over lossy RF, not a per-drone tuning knob.

**Codec note (operator):** picam streams **H.264** (Zero 2 W has no HW H.265 encode), so
on the GCS, QGroundControl's video setting must be **H.264** for a picam drone. One-time
QGC setting — documented, not code.

### 2. Pi-cam GStreamer pipeline (GCS only)

```bash
gst-launch-1.0 \
  libcamerasrc ! \
  video/x-raw,width=${OUTPUT_WIDTH},height=${OUTPUT_HEIGHT},framerate=${OUTPUT_FPS}/1 ! \
  videoconvert ! \
  v4l2h264enc extra-controls="controls,video_bitrate=$((OUTPUT_BITRATE*1000)),h264_i_frame_period=${OUTPUT_FPS}" ! \
  h264parse ! \
  rtph264pay config-interval=1 pt="${PT}" mtu="${MTU}" ! \
  udpsink host="${GCS_IP}" port="${VIDEO_PORT}" sync=false async=false
```

- `libcamerasrc` (from `gstreamer1.0-libcamera`) — CSI capture, no network source.
- `v4l2h264enc` — the Zero 2 W bcm2835 **hardware** H.264 encoder (the whole win).
- `extra-controls` — `video_bitrate` in **bits/s** (`OUTPUT_BITRATE` kbps × 1000);
  `h264_i_frame_period` = one keyframe/second (`OUTPUT_FPS` frames).
- `rtph264pay config-interval=1` — re-send SPS/PPS every second so a mid-stream/lossy GCS
  can start decoding (otherwise: black screen until next keyframe). Hardcoded, not from env.

**Verify-on-hardware caveat (not a decision):**
1. Format negotiation — `libcamerasrc` usually emits `NV12`/`YU12`; `v4l2h264enc` accepts
   those. `videoconvert` is a cheap safety net; drop it if caps negotiate directly.

### 3. `camera-relay.sh` branch

Early-exit branch at the top, right after sourcing the env, before all existing IP logic:
```bash
source /etc/specter/camera-relay.env || { echo "ERROR: camera-relay.env not found" >&2; exit 1; }

if [ "${CAMERA_SOURCE:-ip}" = "picam" ]; then
  exec gst-launch-1.0 \
    libcamerasrc ! ... ! v4l2h264enc ... ! rtph264pay ... ! udpsink ...
fi

# --- existing IP-camera (rtspsrc / H.265) logic unchanged below ---
```
`exec` means the picam path never reaches the IP logic; the existing file is untouched below.

### 4. `setup_camera.sh` conditional install

Read `CAMERA_SOURCE` (after copying the env template) and branch:
- Always: base GStreamer bundle (unchanged).
- `picam` → also `apt install -y gstreamer1.0-libcamera rpicam-apps`; **skip** the
  `nmcli con add camera eth0` static-IP block (IP-camera-only; no eth0 on Zero 2 W).
- `ip` → unchanged (eth0 nmcli as today).

Camera detection: on Debian-13 RPi OS, `camera_auto_detect=1` is default, so a seated CSI
ribbon is auto-detected by libcamera — no `config.txt` edit in the common case. Add a
non-fatal detection check (`rpicam-hello --list-cameras`) so a bad/unseated ribbon warns
at install rather than failing silently at stream time.

## Testing

1. **`shellcheck`** — CI already lints `scripts/*.sh`; the added branch stays clean.
2. **On-hardware acceptance** (Zero 2 W + CSI camera + laptop on the AP):
   - `CAMERA_SOURCE=picam`, start `camera-relay`.
   - QGroundControl → video (H.264, UDP `5600`) → **live video appears**.
   - `htop` during stream → `v4l2h264enc` at **single-digit % CPU**. This is the real
     acceptance: video appearing while CPU is pegged near 100% would mean a silent
     software fallback — the exact failure this change exists to avoid.
   - **No FC, GPS, or distance needed** — just the AP + laptop + camera.

## Success criteria

- With `CAMERA_SOURCE=ip` (default), the camera path is byte-for-byte unchanged.
- With `CAMERA_SOURCE=picam` on a Zero 2 W + CSI camera, QGC shows live H.264 video on
  `VIDEO_PORT`, and the encoder runs on hardware (low CPU).
- `setup_camera.sh` installs libcamera deps and skips the eth0 step in picam mode.
- `shellcheck` clean in CI.

## Open items for the implementation plan

- Exact `libcamerasrc` output caps / whether `videoconvert` is needed (verify on-device).
- Whether to add a `picam` convenience profile, or leave source selection purely to
  `camera-relay.env` (leaning: env-only in v1 — profiles pick *modules*, not sub-modes).
- Confirm the CSI camera model in use (v2/v3/HQ) for any libcamera version caveat.
