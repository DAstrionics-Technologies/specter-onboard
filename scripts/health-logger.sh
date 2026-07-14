#!/bin/bash
# health-logger.sh — sample WiFi link + Pi health to CSV. On-demand range/endurance tool.
# NOTE: intentionally no `set -e` — the sampling loop must survive transient errors.

parse_station() {
  # stdin: `iw dev <iface> station dump` output
  # stdout: connected,signal_dbm,signal_avg_dbm,tx_bitrate_mbps,rx_bitrate_mbps,tx_retries,tx_failed,inactive_ms
  awk '
    BEGIN { c=0; sig=""; savg=""; tbr=""; rbr=""; tr=""; tf=""; inact="" }
    /^Station/            { c=1 }
    /inactive time:/      { inact=$3 }
    /^[[:space:]]*signal:/ { sig=$2 }
    /signal avg:/         { savg=$3 }
    /tx bitrate:/         { tbr=$3 }
    /rx bitrate:/         { rbr=$3 }
    /tx retries:/         { tr=$3 }
    /tx failed:/          { tf=$3 }
    END { printf "%s,%s,%s,%s,%s,%s,%s,%s\n", c, sig, savg, tbr, rbr, tr, tf, inact }
  '
}

sample_health() {
  # stdout: temp_c,throttled,load1,mem_avail_mb,uptime_s  (blank fields on any error)
  local temp throttled load1 memkb memmb uptime
  temp="$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9.]+' || true)"
  throttled="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || true)"
  load1="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)"
  memkb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  memmb=""
  [ -n "$memkb" ] && memmb=$(( memkb / 1024 ))
  uptime="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || true)"
  printf '%s,%s,%s,%s,%s\n' "$temp" "$throttled" "$load1" "$memmb" "$uptime"
}

main() {
  [ -f /etc/specter/health-logger.env ] && . /etc/specter/health-logger.env
  if [ -z "${IFACE:-}" ]; then
    [ -f /etc/specter/wifi.env ] && . /etc/specter/wifi.env
    IFACE="${WIFI_INTERFACE:-wlan1}"
  fi
  SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
  LOG_DIR="${LOG_DIR:-/var/log/specter}"
  mkdir -p "$LOG_DIR" /run/specter

  local csv
  csv="$LOG_DIR/health-$(date +%Y%m%d-%H%M%S).csv"
  echo "timestamp,marker_m,connected,signal_dbm,signal_avg_dbm,tx_bitrate_mbps,rx_bitrate_mbps,tx_retries,tx_failed,inactive_ms,temp_c,throttled,load1,mem_avail_mb,uptime_s" > "$csv"
  echo "Logging to $csv (iface=$IFACE, interval=${SAMPLE_INTERVAL}s). Ctrl-C to stop."

  while true; do
    local ts marker link health
    ts="$(date -Is)"
    marker="$(cat /run/specter/health-marker 2>/dev/null || true)"
    link="$(iw dev "$IFACE" station dump 2>/dev/null | parse_station)"
    health="$(sample_health)"
    echo "$ts,$marker,$link,$health" >> "$csv"
    sleep "$SAMPLE_INTERVAL"
  done
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
