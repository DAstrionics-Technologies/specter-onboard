#!/bin/bash
set -e
source /etc/specter/camera-relay.env || { echo "ERROR: camera-relay.env not found" >&2; exit 1; }

if [ "$ENCODE_VIDEO" = "true" ]; then
  exec gst-launch-1.0 \
    rtspsrc location=${VIDEO_URL} latency=${LATENCY} protocols=${PROTOCOLS} drop-on-latency=true ! \
    rtph265depay ! h265parse ! avdec_h265 ! \
    videoscale ! video/x-raw,width=${OUTPUT_WIDTH},height=${OUTPUT_HEIGHT} ! \
    videorate ! video/x-raw,framerate=${OUTPUT_FPS}/1 ! \
    x265enc bitrate=${OUTPUT_BITRATE} tune=zerolatency ! \
    rtph265pay config-interval=${CONFIG_INTERVAL} pt=${PT} mtu=${MTU} ! \
    queue max-size-buffers=1 leaky=downstream ! \
    udpsink host=${GCS_IP} port=${VIDEO_PORT} sync=false async=false
else
  if [ "$CLOUD_STREAM" = "true" ]; then
    exec gst-launch-1.0 \
      rtspsrc location=${VIDEO_URL} latency=${LATENCY} protocols=${PROTOCOLS} drop-on-latency=true ! \
      rtph265depay ! tee name=t \
        t. ! queue max-size-buffers=1 leaky=downstream ! \
          rtph265pay config-interval=${CONFIG_INTERVAL} pt=${PT} mtu=${MTU} aggregate-mode=zero-latency ! \
          queue max-size-buffers=1 leaky=downstream ! \
          udpsink host=${GCS_IP} port=${VIDEO_PORT} sync=false async=false \
        t. ! queue max-size-buffers=1 leaky=downstream ! \
          h265parse ! \
          rtspclientsink location=${CLOUD_URL} protocols=tcp latency=0
  else
    exec gst-launch-1.0 \
      rtspsrc location=${VIDEO_URL} latency=${LATENCY} protocols=${PROTOCOLS} drop-on-latency=true ! \
      rtph265depay ! \
      rtph265pay config-interval=${CONFIG_INTERVAL} pt=${PT} mtu=${MTU} aggregate-mode=zero-latency ! \
      queue max-size-buffers=1 leaky=downstream ! \
      udpsink host=${GCS_IP} port=${VIDEO_PORT} sync=false async=false
  fi
fi