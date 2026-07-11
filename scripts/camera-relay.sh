#!/bin/bash
source /etc/specter/camera-relay.env || { echo "ERROR: camera-relay.env not found" >&2; exit 1; }

if [ "$ENCODE_VIDEO" = "true" ]; then
  exec gst-launch-1.0 \
    rtspsrc location="${VIDEO_URL}" latency="${LATENCY}" protocols="${PROTOCOLS}" drop-on-latency=true ! \
    rtph265depay ! h265parse ! avdec_h265 ! \
    videoscale ! video/x-raw,width="${OUTPUT_WIDTH}",height="${OUTPUT_HEIGHT}" ! \
    videorate ! video/x-raw,framerate="${OUTPUT_FPS}"/1 ! \
    x265enc bitrate="${OUTPUT_BITRATE}" tune=zerolatency ! \
    rtph265pay config-interval="${CONFIG_INTERVAL}" pt="${PT}" mtu="${MTU}" ! \
    queue max-size-buffers=1 leaky=downstream ! \
    udpsink host="${GCS_IP}" port="${VIDEO_PORT}" sync=false async=false
else
  if [ "$CLOUD_STREAM" = "true" ]; then
    # GCS pipeline (primary — must always work)
    gst-launch-1.0 \
      rtspsrc location="${VIDEO_URL}" latency="${LATENCY}" protocols="${PROTOCOLS}" drop-on-latency=true ! \
      rtph265depay ! \
      rtph265pay config-interval="${CONFIG_INTERVAL}" pt="${PT}" mtu="${MTU}" aggregate-mode=zero-latency ! \
      queue max-size-buffers=1 leaky=downstream ! \
      udpsink host="${GCS_IP}" port="${VIDEO_PORT}" sync=false async=false &
    GCS_PID=$!

    # Cloud pipeline (secondary — can fail independently)
    while true; do
      gst-launch-1.0 \
        rtspsrc location="${VIDEO_URL}" latency="${LATENCY}" protocols="${PROTOCOLS}" drop-on-latency=true ! \
        rtph265depay ! h265parse ! \
        rtspclientsink location="${CLOUD_URL}" protocols=tcp latency=0
      echo "Cloud pipeline exited, retrying in 5s..."
      sleep 5
    done &
    CLOUD_PID=$!

    # If GCS dies, kill cloud and exit (systemd restarts both)
    wait "$GCS_PID"
    kill "$CLOUD_PID" 2>/dev/null || true
  else
    exec gst-launch-1.0 \
      rtspsrc location="${VIDEO_URL}" latency="${LATENCY}" protocols="${PROTOCOLS}" drop-on-latency=true ! \
      rtph265depay ! \
      rtph265pay config-interval="${CONFIG_INTERVAL}" pt="${PT}" mtu="${MTU}" aggregate-mode=zero-latency ! \
      queue max-size-buffers=1 leaky=downstream ! \
      udpsink host="${GCS_IP}" port="${VIDEO_PORT}" sync=false async=false
  fi
fi
