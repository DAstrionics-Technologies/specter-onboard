# Onboard Health & Link Logger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local-first CSV logger that samples WiFi link quality + Pi system health for range/endurance testing.

**Architecture:** A single bash script (`health-logger.sh`) with a testable `parse_station()` function and a defensive sampling loop, installed as an on-demand (disabled-by-default) systemd unit via a `health` module in the existing profile system.

**Tech Stack:** Bash, `iw`, `vcgencmd`, procfs, systemd, shellcheck. Target: Raspberry Pi OS (Debian 13), aarch64.

## Global Constraints

- **Local-first, offline** — no cloud/API-key/GPS/MAVLink dependency.
- **System + link data only** — `iw dev <iface> station dump` + `vcgencmd`/procfs.
- **CSV output**, one timestamped file per run, to `LOG_DIR` (default `/var/log/specter`).
- **On-demand service** — installed **disabled**; operator starts/stops it around a test.
- **Robust loop** — `health-logger.sh` uses **no `set -e`**; every field captured defensively (blank on error), loop never exits on a sample error.
- CSV columns (exact order): `timestamp,marker_m,connected,signal_dbm,signal_avg_dbm,tx_bitrate_mbps,rx_bitrate_mbps,tx_retries,tx_failed,inactive_ms,temp_c,throttled,load1,mem_avail_mb,uptime_s`
- Branch: `feat/health-logger`, stacked on `feat/modular-install` (provides the orchestrator + module system).

---

### Task 1: `parse_station()` + test (TDD)

**Files:**
- Create: `scripts/health-logger.sh`
- Create: `tests/test_health_parse.sh`

**Interfaces:**
- Produces: `parse_station()` — reads `iw station dump` text on stdin, emits
  `connected,signal_dbm,signal_avg_dbm,tx_bitrate_mbps,rx_bitrate_mbps,tx_retries,tx_failed,inactive_ms`.
  Sourcing the script must NOT run the loop (main-guard).

- [ ] **Step 1: Write the failing test**

Create `tests/test_health_parse.sh`:
```bash
#!/bin/bash
# Offline tests for parse_station() — no hardware needed.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/health-logger.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1"; echo "  want: $2"; echo "  got:  $3"; fail=1; fi; }

dump="$(cat <<'EOF'
Station 94:ba:06:cc:b4:a7 (on wlan1)
	inactive time:	40 ms
	tx retries:	12
	tx failed:	0
	signal:  	-52 dBm
	signal avg:	-53 dBm
	tx bitrate:	72.2 MBit/s
	rx bitrate:	65.0 MBit/s
EOF
)"
check "connected station parses" "1,-52,-53,72.2,65.0,12,0,40" "$(printf '%s\n' "$dump" | parse_station)"
check "empty dump -> connected 0" "0,,,,,,," "$(printf '' | parse_station)"
exit $fail
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_health_parse.sh`
Expected: FAIL — `scripts/health-logger.sh` does not exist (source error) / `parse_station: command not found`.

- [ ] **Step 3: Create `scripts/health-logger.sh` with `parse_station()` + main-guard**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_health_parse.sh`
Expected: both `PASS:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/health-logger.sh tests/test_health_parse.sh
git commit -m "feat: parse_station() for health-logger + offline tests"
```

---

### Task 2: `sample_health()` + sampling loop

**Files:**
- Modify: `scripts/health-logger.sh` (replace the `main()` stub, add `sample_health()`)

**Interfaces:**
- Consumes: `parse_station()` (Task 1).
- Produces: running `health-logger.sh` writes `${LOG_DIR}/health-<ts>.csv` with the 15-column
  schema at `SAMPLE_INTERVAL`. `IFACE` defaults to `WIFI_INTERFACE` from `wifi.env` (`wlan1`).

- [ ] **Step 1: Add `sample_health()` above `main()`**

```bash
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
```

- [ ] **Step 2: Replace the `main()` stub**

```bash
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
```

- [ ] **Step 3: Verify syntax + tests still pass**

Run: `bash -n scripts/health-logger.sh && bash tests/test_health_parse.sh`
Expected: no syntax error; both tests still PASS (main-guard keeps the loop from running when sourced).

- [ ] **Step 4: On-hardware smoke test** (on the Pi)

Run:
```bash
sudo timeout 3 bash scripts/health-logger.sh
head -2 /var/log/specter/health-*.csv
```
Expected: a header line + at least one data row; with a laptop associated, `connected=1` and `signal_dbm` populated; `temp_c` present.

- [ ] **Step 5: Commit**

```bash
git add scripts/health-logger.sh
git commit -m "feat: health sampling loop (link + system health -> CSV)"
```

---

### Task 3: Install wiring — `health` module + `range-test` profile

**Files:**
- Create: `scripts/setup_health.sh`
- Create: `systemd/health-logger.service`
- Create: `config/health-logger.env.template`
- Create: `profiles/range-test.conf`
- Modify: `install.sh` (add `health` to `CANONICAL_MODULES` and `MODULE_SERVICE`)
- Modify: `tests/test_install.sh` (add a `range-test` dry-run assertion)

**Interfaces:**
- Consumes: `install.sh` orchestrator + module contract (from `feat/modular-install`).
- Produces: `./install.sh --profile range-test` brings up `wifi` and stages `health`
  (installed, service **disabled** → summary shows `health OK inactive`).

- [ ] **Step 1: Create `systemd/health-logger.service`**

```ini
[Unit]
Description=Specter Health & Link Logger
After=network.target

[Service]
Type=simple
ExecStart=/opt/specter/bin/health-logger.sh
Restart=no

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Create `config/health-logger.env.template`**

```ini
# Interface to measure. Blank = use WIFI_INTERFACE from /etc/specter/wifi.env (wlan1).
IFACE=
SAMPLE_INTERVAL=1
LOG_DIR=/var/log/specter
```

- [ ] **Step 3: Create `scripts/setup_health.sh`**

```bash
#!/bin/bash
set -euo pipefail

echo "--- Health Logger Setup ---"

sudo mkdir -p /opt/specter/bin /etc/specter /var/log/specter

sudo cp "$SCRIPT_DIR"/scripts/health-logger.sh /opt/specter/bin/health-logger.sh
sudo chmod +x /opt/specter/bin/health-logger.sh

sudo cp "$SCRIPT_DIR"/config/health-logger.env.template /etc/specter/health-logger.env
sudo cp "$SCRIPT_DIR"/systemd/health-logger.service /etc/systemd/system/health-logger.service
sudo systemctl daemon-reload

# On-demand diagnostic: install but do NOT enable/start. Operator runs it for a test.
sudo systemctl disable health-logger 2>/dev/null || true

echo "--- Health Logger installed (run a test: sudo systemctl start health-logger) ---"
echo "health-logger: $(systemctl is-active health-logger)"
```

- [ ] **Step 4: Create `profiles/range-test.conf`**

```
# range-test — bring up the AP + stage the health logger for a range/endurance test
wifi
health
```

- [ ] **Step 5: Register the `health` module in `install.sh`**

Change the canonical list to append `health`:
```bash
CANONICAL_MODULES=(wifi mavlink camera cellular telemetry health)
```
Add to the `MODULE_SERVICE` map (before the closing `)`):
```bash
  [health]="health-logger"
```

- [ ] **Step 6: Add a `range-test` assertion to `tests/test_install.sh`**

After the existing `scout` assertion, add:
```bash
want_in "range-test selects wifi+health" \
  "modules (canonical order): wifi health" \
  "$(bash "$INSTALL" --profile range-test --dry-run)"
```

- [ ] **Step 7: Verify dry-run + tests**

Run: `bash tests/test_install.sh && bash "$PWD/install.sh" --profile range-test --dry-run`
Expected: all `PASS:`; dry-run prints `modules (canonical order): wifi health`.

- [ ] **Step 8: On-hardware acceptance** (on the Pi)

Run:
```bash
./install.sh --profile range-test
```
Expected summary rows: `wifi OK active`, `health OK inactive`. Then:
```bash
sudo systemctl start health-logger
echo 5 | sudo tee /run/specter/health-marker
sleep 3
sudo systemctl stop health-logger
tail -3 /var/log/specter/health-*.csv
```
Expected: rows with `marker_m=5`, health columns populated (and link columns if a laptop is associated).

- [ ] **Step 9: Commit**

```bash
git add scripts/setup_health.sh systemd/health-logger.service config/health-logger.env.template profiles/range-test.conf install.sh tests/test_install.sh
git commit -m "feat: health module + range-test profile (on-demand logger install)"
```

---

## Final verification (before PR)

- [ ] `bash tests/test_health_parse.sh` passes
- [ ] `bash tests/test_install.sh` passes (incl. range-test)
- [ ] `shellcheck` clean in CI for `health-logger.sh`, `setup_health.sh`, `test_health_parse.sh`
- [ ] On the Pi: `--profile range-test` → `wifi OK active`, `health OK inactive`; starting the logger writes a CSV with the marker and health columns.
- [ ] Confirmed with **no FC/GPS/camera** connected.
