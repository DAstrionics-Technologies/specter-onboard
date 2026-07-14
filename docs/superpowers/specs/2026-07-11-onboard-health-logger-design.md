# Onboard Health & Link Logger — Design

**Date:** 2026-07-11
**Status:** Approved (design), pending implementation plan
**Repo:** specter-onboard
**Branch:** `feat/health-logger` (stacked on `feat/modular-install`, which provides the module/profile system)

## Problem

Range and endurance testing today is eyeball-and-vibes: we watched `vcgencmd`
and `iw` by hand during bring-up, but nothing records link quality or system
health over time. There's no way to answer "how far does the air-ground link
reach?" or "does the Pi thermal-throttle over a 3-hour run?" with data.

`telemetry_sender.py` is not the tool: it's flight-telemetry only (position,
battery, mode → cloud) and *refuses to run* without an API key, cloud endpoint,
and GPS fix — the exact conditions absent during a field range test.

## Goal

A local-first, offline diagnostic that samples WiFi link quality and Pi system
health to a CSV file on the SD card, for pull-and-plot analysis after a test.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Primary purpose | Range/endurance test tool, **local-first** | Runs in the field with no cloud/API-key/GPS. |
| Data sources | **System + link only** (no MAVLink/GPS) | Zero FC dependency; runs on a bare Pi. |
| Output | **CSV**, one file per run | Opens in Sheets/pandas; trivial to plot. |
| Implementation | **Bash script + on-demand systemd unit** (Approach A) | Matches the shell-first stack; no Python dep; simple sampler. |
| Distance method | **Stepped static test + live `marker_m` column** | Clean per-distance RSSI plateaus; self-contained (no GPS, no paper notes). |
| Service default | **Installed but disabled** (start on demand) | Diagnostic, not an always-on service — avoids constant SD writes. |

## Non-goals (YAGNI)

- No cloud push (later add-on; local file is the v1 output).
- No MAVLink/GPS in the logger (distance is external/marker-driven).
- No both-ends RSSI (drone-side `iw station dump` only; GCS-side is a separate future logger).
- No SQLite/rotation — one CSV per run; SD has ample space (~1 Hz CSV ≈ a few MB/hour).

## How the range test physically works

The laptop (GCS) associates directly to the drone's own WiFi AP — that 5 GHz
link **is** the thing under test. No router/infrastructure.

```
Drone (Pi + RTL8822CU)                    Laptop (GCS)
wlan1 = AP "Specter-Drone"  ◄─ 5 GHz ─►   WiFi client
192.168.10.1                 direct link   192.168.10.x (DHCP)
running health-logger
```

The operator drives the logger via **SSH from the laptop to `192.168.10.1`
over that same link**. At each distance step the laptop is still associated, so
SSH works to set the marker; at max range SSH degrades and drops *with* the
link, and that drop (`connected → 0`) is the range answer. Drone on a
tripod/mast, antennas vertical, open line-of-sight; move the laptop.

## Architecture

### Files

```
scripts/health-logger.sh           # sampler loop + parse_station() function
scripts/setup_health.sh            # installs script + service (leaves it DISABLED)
systemd/health-logger.service      # Type=simple; NOT enabled on boot
config/health-logger.env.template  # IFACE, SAMPLE_INTERVAL, LOG_DIR
tests/test_health_parse.sh         # feeds captured `iw` output through parse_station()
profiles/range-test.conf           # wifi + health (convenience profile)
```

Plus: add `health` to `CANONICAL_MODULES` and the `MODULE_SERVICE` map in
`install.sh` (from the stacked `feat/modular-install` branch).

### CSV schema

Header + one row per sample:

```
timestamp,marker_m,connected,signal_dbm,signal_avg_dbm,tx_bitrate_mbps,rx_bitrate_mbps,tx_retries,tx_failed,inactive_ms,temp_c,throttled,load1,mem_avail_mb,uptime_s
```

- `timestamp` — ISO-8601 (NTP-synced; pandas-parsable).
- `marker_m` — current value of `/run/specter/health-marker` (blank until set). The range axis.
- `connected` — `1` if a station is associated, else `0`. The `1 → 0` transition at a given
  `marker_m` is the max usable range.
- link (`iw station dump`) — `signal_dbm`, `signal_avg_dbm`, `tx/rx_bitrate_mbps`,
  `tx_retries`, `tx_failed`, `inactive_ms`.
- health (`vcgencmd`/procfs) — `temp_c`, `throttled` (hex bitmask), `load1`,
  `mem_avail_mb`, `uptime_s`.

When no station is associated, link columns are blank and `connected=0`; health columns
still populate (so the moment of link-loss is captured, not the end of the log).

### `health-logger.sh` structure

```bash
parse_station() { ... reads stdin (iw station dump text), emits:
                     connected,signal_dbm,signal_avg_dbm,tx_bitrate_mbps,rx_bitrate_mbps,tx_retries,tx_failed,inactive_ms }
main() {
  # source config; IFACE defaults to WIFI_INTERFACE from wifi.env (wlan1)
  # open ${LOG_DIR}/health-<YYYYmmdd-HHMMSS>.csv, write header
  # loop every SAMPLE_INTERVAL:
  #   link=$(iw dev "$IFACE" station dump | parse_station)
  #   temp/throttled/load1/mem_avail/uptime from vcgencmd + procfs
  #   marker=$(cat /run/specter/health-marker 2>/dev/null)
  #   append CSV row; sleep
}
# main-guard: lets tests source the file for parse_station without running the loop
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

**Robustness:** each field captured defensively — a missing tool or unexpected output
writes that field blank and the loop continues. The loop never exits on a sample error
(a logger that dies mid-endurance-run is worse than one with a few blank cells).

### Marker mechanism

`/run/specter/health-marker` on tmpfs. Set live during a stepped test:
```bash
echo 100 | sudo tee /run/specter/health-marker   # now at 100 m
```
Every subsequent sample stamps `marker_m=100` until changed.

### Install & run

`setup_health.sh`: install `health-logger.sh` → `/opt/specter/bin/`, stage the env template
to `/etc/specter/health-logger.env`, `mkdir -p /var/log/specter`, install
`health-logger.service` but leave it **disabled** (do not enable/start). Install summary
therefore shows `health  OK  inactive` — correct for an on-demand tool.

Run a test:
```bash
./install.sh --profile range-test     # AP up + logger staged
# connect laptop to the drone AP, then SSH in over the link
sudo systemctl start health-logger
# step out: hold at each distance, set marker, wait ~45s
sudo systemctl stop health-logger
# pull /var/log/specter/health-*.csv and plot
```

## Testing

1. **`tests/test_health_parse.sh`** (offline, CI) — source `health-logger.sh` (main-guard
   suppresses the loop), run `parse_station` against fixtures:
   - connected-station dump → `1,-52,-53,72.2,65.0,12,0,40`
   - empty input → `0,,,,,,,`
2. **`shellcheck`** — already lints `scripts/*.sh` + `tests/*.sh` in CI.
3. **On-hardware acceptance** — bench walk-away: `--profile range-test`, connect laptop,
   start logger, carry laptop away; confirm CSV shows `signal_dbm` falling, `tx_retries`
   rising, and `connected` flipping to `0` at the edge. **No FC required.**

## Success criteria

- `./install.sh --profile range-test` brings up the AP and stages the logger
  (`health OK inactive`).
- `systemctl start health-logger` writes a timestamped CSV with the full schema at ~1 Hz.
- Setting `/run/specter/health-marker` changes `marker_m` in subsequent rows.
- With the laptop associated, link columns populate; when it disconnects, `connected=0`
  and health columns keep logging.
- `test_health_parse.sh` + shellcheck pass in CI.
- The whole rig works with **no flight controller, GPS, or camera** connected.

## Open items for the implementation plan

- Exact `iw station dump` field regexes (signal/bitrate/retries) and the fixture capture.
- Whether `setup_health.sh` should `systemctl disable` explicitly (vs. just not enabling).
- `range-test.conf` ordering note: `wifi` before `health` (health has no service dependency,
  but wifi must be up for there to be a station to measure).
