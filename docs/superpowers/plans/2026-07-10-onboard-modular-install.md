# Onboard Modular Install — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the onboard install profile-driven, non-blocking on absent hardware, and free of on-target compilation.

**Architecture:** A thin `install.sh` orchestrator reads a named profile (`profiles/<name>.conf`), then runs each selected module's existing `setup_<module>.sh` in isolation so no failure aborts the others. Each module script splits into a fatal "install" phase and a non-fatal "activate" phase. `mavlink-routerd` ships as a committed prebuilt binary (already added) that scripts copy instead of compiling.

**Tech Stack:** Bash, systemd, shellcheck. Target: Raspberry Pi OS (Debian 13 trixie), aarch64.

## Global Constraints

- Fleet is **uniform Debian 13 (trixie), aarch64** — one committed binary covers all boards.
- Delivery stays **git-clone**; no releases/LFS/image system.
- Only **`mavlink-routerd`** ships as a binary; everything else is `apt install` + copy-scripts.
- **`install.sh` requires `--profile`** — no silent default.
- Absent hardware at install = **install fully, enable, tolerate** (never fatal).
- All setup scripts stay **idempotent**.
- The mavlink binary lives at **`/usr/bin/mavlink-routerd`** (matches the service unit).
- Canonical module order (fixed): **`wifi mavlink camera cellular telemetry`** (telemetry's service `Requires=mavlink-router`).
- Module → service map: `wifi→drone-wifi`, `mavlink→mavlink-router`, `camera→camera-relay`, `cellular→(none, nmcli connection)`, `telemetry→telemetry-sender`.

**Already done on this branch (`feat/modular-install`):**
- Spec: `docs/superpowers/specs/2026-07-09-onboard-modular-install-design.md`
- Binary: `bin/mavlink-routerd` (v4-15-g51983a4, aarch64, proven on Zero 2 W) + `bin/mavlink-routerd.version`
- Working tree (uncommitted): `scripts/setup_wifi.sh` driver-guard fix (approach C) — folded into Task 4.

---

### Task 1: Profiles + canonical module set

**Files:**
- Create: `profiles/full.conf`, `profiles/scout.conf`, `profiles/bench.conf`

**Interfaces:**
- Produces: profile files consumed by `install.sh` (Task 2). Format: newline-delimited module names, `#` comments and blank lines ignored. Valid names: `wifi mavlink camera cellular telemetry`.

- [ ] **Step 1: Create the three profiles**

`profiles/full.conf`:
```
# full — every module (previous install.sh behavior)
wifi
mavlink
camera
cellular
telemetry
```

`profiles/scout.conf`:
```
# scout — air-ground link + FC routing + cloud telemetry, no camera/cellular
wifi
mavlink
telemetry
```

`profiles/bench.conf`:
```
# bench — minimal bring-up for testing
wifi
mavlink
```

- [ ] **Step 2: Commit**

```bash
git add profiles/
git commit -m "feat: add install profiles (full, scout, bench)"
```

---

### Task 2: `install.sh` orchestrator + dry-run + tests

**Files:**
- Modify (full rewrite): `install.sh`
- Create: `tests/test_install.sh`

**Interfaces:**
- Consumes: `profiles/*.conf` (Task 1); `scripts/setup_<module>.sh` (existing/Tasks 3–4).
- Produces: `./install.sh --profile <name> [--dry-run]`. Dry-run prints `modules (canonical order): <space-separated>` and requires no root/hardware. Real run executes modules isolated, writes `/etc/specter/installed-profile`, prints a summary, exits non-zero iff any module install FAILED. Honors `SPECTER_PROFILES_DIR` env override (for tests).

- [ ] **Step 1: Write the failing test**

Create `tests/test_install.sh`:
```bash
#!/bin/bash
# Dependency-free dry-run logic tests for install.sh (no root/hardware).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"
fail=0

want_in() { # desc, needle, haystack
  if printf '%s' "$3" | grep -qF "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; echo "  wanted: $2"; echo "  got:    $3"; fail=1; fi
}
want_nonzero() { # desc, cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL: $desc (expected non-zero exit)"; fail=1; else echo "PASS: $desc"; fi
}

want_in "bench selects wifi+mavlink" \
  "modules (canonical order): wifi mavlink" \
  "$(bash "$INSTALL" --profile bench --dry-run)"

want_in "scout ordered wifi mavlink telemetry" \
  "modules (canonical order): wifi mavlink telemetry" \
  "$(bash "$INSTALL" --profile scout --dry-run)"

# Canonical ordering must not depend on file order.
tmp="$(mktemp -d)"; printf 'telemetry\nwifi\nmavlink\n' > "$tmp/reversed.conf"
want_in "out-of-order profile still canonical" \
  "modules (canonical order): wifi mavlink telemetry" \
  "$(SPECTER_PROFILES_DIR="$tmp" bash "$INSTALL" --profile reversed --dry-run)"
printf 'wifi\nbogus\n' > "$tmp/typo.conf"
want_nonzero "typo'd module name rejected" env SPECTER_PROFILES_DIR="$tmp" bash "$INSTALL" --profile typo --dry-run
rm -rf "$tmp"

want_nonzero "unknown profile rejected" bash "$INSTALL" --profile nope --dry-run
want_nonzero "missing --profile rejected"  bash "$INSTALL" --dry-run

exit $fail
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_install.sh`
Expected: FAIL (current `install.sh` has no `--profile`/`--dry-run`; output won't contain the expected lines).

- [ ] **Step 3: Rewrite `install.sh`**

```bash
#!/bin/bash
# Specter Onboard installer — profile-driven, non-blocking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SPECTER_PROFILES_DIR:-$SCRIPT_DIR/profiles}"

CANONICAL_MODULES=(wifi mavlink camera cellular telemetry)
declare -A MODULE_SERVICE=(
  [wifi]="drone-wifi"
  [mavlink]="mavlink-router"
  [camera]="camera-relay"
  [cellular]=""
  [telemetry]="telemetry-sender"
)

DRY_RUN=0
PROFILE=""

die() { echo "ERROR: $*" >&2; exit 1; }

list_profiles() {
  echo "Available profiles:" >&2
  local f
  for f in "$PROFILES_DIR"/*.conf; do
    [ -e "$f" ] || continue
    echo "  - $(basename "$f" .conf)" >&2
  done
}

usage() {
  echo "Usage: ./install.sh --profile <name> [--dry-run]" >&2
  echo "Installs the onboard modules listed in profiles/<name>.conf." >&2
  list_profiles
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "unknown argument: $1" ;;
  esac
done

[ -n "$PROFILE" ] || { usage; die "--profile is required"; }
PROFILE_FILE="$PROFILES_DIR/$PROFILE.conf"
[ -f "$PROFILE_FILE" ] || { list_profiles; die "unknown profile: $PROFILE"; }

is_canonical() {
  local m
  for m in "${CANONICAL_MODULES[@]}"; do [ "$m" = "$1" ] && return 0; done
  return 1
}

declare -a REQUESTED=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -n "$line" ] || continue
  is_canonical "$line" || die "profile '$PROFILE' names unknown module: '$line'"
  REQUESTED+=("$line")
done < "$PROFILE_FILE"

declare -a SELECTED=()
for m in "${CANONICAL_MODULES[@]}"; do
  for r in "${REQUESTED[@]:-}"; do
    [ "$m" = "$r" ] && { SELECTED+=("$m"); break; }
  done
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "profile: $PROFILE"
  echo "modules (canonical order): ${SELECTED[*]:-}"
  exit 0
fi

declare -A RESULT=()
for module in "${SELECTED[@]:-}"; do
  echo "===== $module ====="
  if sudo env SCRIPT_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/setup_${module}.sh"; then
    RESULT[$module]="OK"
  else
    RESULT[$module]="FAILED"
  fi
done

sudo mkdir -p /etc/specter
printf '%s\n' "$PROFILE" | sudo tee /etc/specter/installed-profile >/dev/null

echo
echo "-- Install summary (profile: $PROFILE) --"
printf '%-12s %-9s %s\n' "module" "install" "service"
any_failed=0
for module in "${SELECTED[@]:-}"; do
  svc="${MODULE_SERVICE[$module]}"
  if [ -n "$svc" ]; then
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  else
    state="n/a"
  fi
  printf '%-12s %-9s %s\n' "$module" "${RESULT[$module]}" "$state"
  [ "${RESULT[$module]}" = "FAILED" ] && any_failed=1
done
[ "$any_failed" -eq 0 ] || die "one or more modules failed to install"
echo "Done."
```

- [ ] **Step 4: Run tests + shellcheck to verify pass**

Run: `bash tests/test_install.sh && shellcheck install.sh tests/test_install.sh`
Expected: all `PASS:` lines, test exits 0; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_install.sh
git commit -m "feat: profile-driven, non-blocking install.sh orchestrator with dry-run"
```

---

### Task 3: `setup_mavlink.sh` — prebuilt binary path

**Files:**
- Modify: `scripts/setup_mavlink.sh`

**Interfaces:**
- Consumes: `$SCRIPT_DIR/bin/mavlink-routerd` (committed binary); `scripts/build_mavlink_router.sh` (Task 5, fallback only).
- Produces: `/usr/bin/mavlink-routerd` installed; `mavlink-router.service` enabled; no build toolchain on the common path.

- [ ] **Step 1: Replace the install block**

Replace the `apt install` line **and** the `if ! command -v mavlink-routerd ... fi` build block (top of file) with:
```bash
# Install mavlink-router: prefer the committed prebuilt binary; build only as fallback.
if [ -x "$SCRIPT_DIR/bin/mavlink-routerd" ]; then
  echo "Installing prebuilt mavlink-routerd..."
  sudo install -m 755 "$SCRIPT_DIR/bin/mavlink-routerd" /usr/bin/mavlink-routerd
elif ! command -v mavlink-routerd &>/dev/null; then
  echo "No prebuilt binary found — building from source (slow on low-RAM boards)..."
  bash "$SCRIPT_DIR/scripts/build_mavlink_router.sh" --install
fi
```

- [ ] **Step 2: Make activation non-fatal**

Replace the trailing block (`systemctl start` + `systemctl status`) with:
```bash
sudo systemctl daemon-reload
sudo systemctl enable mavlink-router
sudo systemctl start mavlink-router || true

echo "--- Setup Complete ---"
echo "mavlink-router: $(systemctl is-active mavlink-router)"
```
(Keep the config-staging middle section unchanged. `sudo systemctl enable` stays fatal; `start` becomes non-fatal.)

- [ ] **Step 3: Verify with shellcheck**

Run: `shellcheck scripts/setup_mavlink.sh`
Expected: clean (or only pre-existing, unrelated warnings).

- [ ] **Step 4: On-hardware check (manual, note in commit if run)**

On a Pi with the repo: `sudo env SCRIPT_DIR=$PWD bash scripts/setup_mavlink.sh` then `command -v mavlink-routerd && mavlink-routerd --version` → `/usr/bin/mavlink-routerd`, `v4-15-g51983a4`. (Already validated on the Zero 2 W during design.)

- [ ] **Step 5: Commit**

```bash
git add scripts/setup_mavlink.sh
git commit -m "feat: setup_mavlink uses prebuilt binary, build toolchain only on fallback"
```

---

### Task 4: Two-phase non-fatal contract for wifi/camera/cellular/telemetry

**Files:**
- Modify: `scripts/setup_wifi.sh` (also commits the staged driver-guard fix)
- Modify: `scripts/setup_camera.sh`, `scripts/setup_cellular.sh`, `scripts/setup_telemetry.sh`

**Interfaces:**
- Produces: each module installs+enables (fatal on real error) but tolerates absent hardware (activation non-fatal); no trailing `systemctl status` that aborts under `set -e`.

- [ ] **Step 1: `setup_wifi.sh`** — driver guard already fixed in working tree. Make AP start non-fatal: change `sudo systemctl start drone-wifi` to:
```bash
sudo systemctl start drone-wifi || true
echo "drone-wifi: $(systemctl is-active drone-wifi)"
```

- [ ] **Step 2: `setup_camera.sh`** — make the nmcli profile and service start non-fatal; drop the fatal `systemctl status`. Change the `nmcli con add ...` line to end with `|| true`, and replace the trailing `systemctl start camera-relay` + `systemctl status camera-relay` block with:
```bash
sudo systemctl daemon-reload
sudo systemctl enable camera-relay
sudo systemctl start camera-relay || true
echo "camera-relay: $(systemctl is-active camera-relay)"
```

- [ ] **Step 3: `setup_cellular.sh`** — the real fix: make the modem-dependent steps non-fatal. Change the PIN-unlock block and the bring-up line so absent hardware warns instead of aborting:
```bash
# Unlock SIM if PIN is set (non-fatal — no modem yet is OK)
if [ -n "${SIM_PIN:-}" ]; then
  MODEM_PATH="$(mmcli -L 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Modem/\d+' || true)"
  [ -n "$MODEM_PATH" ] && mmcli -m "$MODEM_PATH" --pin="$SIM_PIN" || echo "No modem detected — skipping PIN unlock."
fi
```
and change `sudo nmcli connection up "$CON_NAME"` to:
```bash
sudo nmcli connection up "$CON_NAME" || echo "Modem not up yet — connection '$CON_NAME' will autoconnect when it appears."
```
(The connection profile is still created with `autoconnect yes`, so it connects when the modem arrives.)

- [ ] **Step 4: `setup_telemetry.sh`** — already implements the contract (the `DRONE_API_KEY` empty-check). Only make the `else`-branch's trailing `systemctl status telemetry-sender` non-fatal:
```bash
    sudo systemctl start telemetry-sender || true
    echo "telemetry-sender: $(systemctl is-active telemetry-sender)"
```

- [ ] **Step 5: Verify with shellcheck**

Run: `shellcheck scripts/setup_wifi.sh scripts/setup_camera.sh scripts/setup_cellular.sh scripts/setup_telemetry.sh`
Expected: clean (or only pre-existing unrelated warnings).

- [ ] **Step 6: Commit**

```bash
git add scripts/setup_wifi.sh scripts/setup_camera.sh scripts/setup_cellular.sh scripts/setup_telemetry.sh
git commit -m "feat: two-phase non-fatal module contract (tolerate absent hardware)"
```

---

### Task 5: `build_mavlink_router.sh` maintainer tool

**Files:**
- Create: `scripts/build_mavlink_router.sh`

**Interfaces:**
- Produces: refreshes `bin/mavlink-routerd` + `bin/mavlink-routerd.version`. `--install` also installs to `/usr/bin` (used by Task 3's fallback). Memory-safe job count.

- [ ] **Step 1: Create the script**

```bash
#!/bin/bash
# Maintainer tool: build mavlink-routerd and refresh the committed binary.
# Not run on drones during normal install (setup_mavlink.sh copies bin/mavlink-routerd).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

sudo apt install -y git meson ninja-build pkg-config gcc g++ systemd systemd-dev

SRC="$(mktemp -d)/mavlink-router"
git clone https://github.com/mavlink-router/mavlink-router "$SRC"
cd "$SRC"
git submodule update --init --recursive

# Memory-safe parallelism: ~400MB per C++ job, capped at nproc.
mem_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
jobs=$(( mem_mb / 400 )); [ "$jobs" -lt 1 ] && jobs=1
maxj=$(nproc); [ "$jobs" -gt "$maxj" ] && jobs="$maxj"
echo "Building with -j$jobs (MemAvailable ${mem_mb}MB)..."

meson setup build . --prefix=/usr
ninja -C build "-j$jobs"

mkdir -p "$SCRIPT_DIR/bin"
install -m 755 build/src/mavlink-routerd "$SCRIPT_DIR/bin/mavlink-routerd"
strip "$SCRIPT_DIR/bin/mavlink-routerd"

ver="$(build/src/mavlink-routerd --version 2>&1 | head -1 | awk '{print $NF}')"
sha="$(sha256sum "$SCRIPT_DIR/bin/mavlink-routerd" | awk '{print $1}')"
cat > "$SCRIPT_DIR/bin/mavlink-routerd.version" <<EOF
version:  $ver
arch:     aarch64 (ARMv8-A) — runs on Zero 2 W (A53) / Pi 4 (A72) / Pi 5 (A76)
libc:     Debian 13 (trixie) glibc, dynamically linked
source:   built by scripts/build_mavlink_router.sh
sha256:   $sha
EOF
echo "Refreshed bin/mavlink-routerd ($ver)"

if [ "$INSTALL" -eq 1 ]; then
  sudo install -m 755 "$SCRIPT_DIR/bin/mavlink-routerd" /usr/bin/mavlink-routerd
  echo "Installed to /usr/bin/mavlink-routerd"
fi
```

- [ ] **Step 2: Verify with shellcheck**

Run: `shellcheck scripts/build_mavlink_router.sh`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/build_mavlink_router.sh
git commit -m "feat: memory-safe build_mavlink_router.sh maintainer tool"
```

---

### Task 6: Profile-aware `update.sh`

**Files:**
- Modify: `update.sh`

**Interfaces:**
- Consumes: `/etc/specter/installed-profile` (written by Task 2).
- Produces: updates only the installed profile's module artifacts/services; restarting a module's service only if that module is in the profile.

- [ ] **Step 1: Read the installed profile and guard per-module actions**

At the top of `update.sh` (after `SCRIPT_DIR=`), add:
```bash
PROFILE="$(cat /etc/specter/installed-profile 2>/dev/null || echo full)"
PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE.conf"
has_module() { [ -f "$PROFILE_FILE" ] && grep -qxF "$1" <(sed 's/#.*//' "$PROFILE_FILE"); }
```
Then guard each module's copy/restart. Replace the unconditional copies + restarts so each is wrapped, e.g.:
```bash
if has_module camera; then
  sudo cp "$SCRIPT_DIR/scripts/camera-relay.sh" /opt/specter/bin/camera-relay.sh
  sudo chmod +x /opt/specter/bin/camera-relay.sh
  sudo cp "$SCRIPT_DIR/systemd/camera-relay.service" /etc/systemd/system/camera-relay.service
fi
if has_module telemetry; then
  sudo cp "$SCRIPT_DIR/src/telemetry_sender.py" /opt/specter/src/telemetry_sender.py
  sudo cp "$SCRIPT_DIR/systemd/telemetry-sender.service" /etc/systemd/system/telemetry-sender.service
fi
if has_module mavlink; then
  sudo cp "$SCRIPT_DIR/systemd/mavlink-router.service" /etc/systemd/system/mavlink-router.service
fi
if has_module wifi; then
  sudo cp "$SCRIPT_DIR/systemd/drone-wifi.service" /etc/systemd/system/drone-wifi.service
fi
sudo systemctl daemon-reload
```
And guard the restarts:
```bash
has_module camera    && sudo systemctl restart camera-relay || true
has_module telemetry && sudo systemctl restart telemetry-sender || true
```
Guard the final status echoes the same way (only print installed services).

- [ ] **Step 2: Verify with shellcheck**

Run: `shellcheck update.sh`
Expected: clean (or only pre-existing warnings).

- [ ] **Step 3: Commit**

```bash
git add update.sh
git commit -m "feat: update.sh only touches modules in the installed profile"
```

---

### Task 7: shellcheck CI + README

**Files:**
- Create: `.github/workflows/shellcheck.yml`
- Modify: `README.md` (Quick Start)

**Interfaces:**
- Produces: CI that runs shellcheck on all scripts + `tests/test_install.sh` on every push/PR; README documents `--profile`.

- [ ] **Step 1: Create the workflow**

`.github/workflows/shellcheck.yml`:
```yaml
name: shellcheck
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Lint scripts
        run: shellcheck install.sh update.sh scripts/*.sh tests/*.sh
      - name: Dry-run tests
        run: bash tests/test_install.sh
```

- [ ] **Step 2: Update README Quick Start**

In `README.md`, replace the bare `./install.sh` instruction with:
```markdown
Install the modules for this drone's hardware by choosing a profile:

```bash
./install.sh --profile scout     # wifi + mavlink + telemetry
./install.sh --profile full      # everything
./install.sh --profile bench     # wifi + mavlink only
./install.sh --profile scout --dry-run   # preview without installing
```

Profiles live in `profiles/*.conf` — edit or add your own. A module whose
hardware isn't connected still installs and enables; its service starts
automatically once the hardware appears.
```

- [ ] **Step 3: Verify**

Run: `shellcheck install.sh update.sh scripts/*.sh tests/*.sh && bash tests/test_install.sh`
Expected: clean + tests pass (mirrors what CI runs).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/shellcheck.yml README.md
git commit -m "ci: shellcheck + dry-run tests; docs: profile-based Quick Start"
```

---

## Final verification (before PR)

- [ ] `shellcheck install.sh update.sh scripts/*.sh tests/*.sh` clean
- [ ] `bash tests/test_install.sh` passes
- [ ] On the Zero 2 W: `./install.sh --profile bench` → summary shows `wifi OK active`, `mavlink OK active`; camera/cellular absent.
- [ ] `cat /etc/specter/installed-profile` → `bench`
- [ ] Push branch, open PR against `main`.
