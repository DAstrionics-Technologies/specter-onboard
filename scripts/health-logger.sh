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

main() { :; }  # implemented in Task 2

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
