# Onboard Modular Install — Design

**Date:** 2026-07-09
**Status:** Approved (design), pending implementation plan
**Repo:** specter-onboard

## Problem

The onboard install (`install.sh`) is all-or-nothing, order-fragile, and blocks on
absent hardware:

- It runs all five setup scripts (`wifi`, `mavlink`, `camera`, `cellular`, `telemetry`)
  unconditionally, in a fixed order, under `set -e`. A failure in any one aborts the rest.
  (Observed: a WiFi driver-build failure took down the other four modules.)
- There is no way to say "this drone has WiFi + MAVLink but no camera or cellular."
- Modules whose hardware is not connected at install time can hard-fail the whole run
  (e.g. `setup_cellular.sh` calls `nmcli connection up`, which fails with no modem).
- `mavlink-router` is **compiled from source on every drone**. On a Pi Zero 2 W
  (~200 MB usable RAM after 256 MB CMA reservation) the parallel C++ build is killed
  by the OOM killer.

## Goals

1. **Modular install** — a drone declares which modules it wants; only those install.
2. **Non-blocking install** — a failed module, or hardware absent at install time,
   does not abort the remaining modules.
3. **Prebuilt `mavlink-routerd`** — ship a committed binary so drones do not compile.

## Non-goals (explicit YAGNI)

- No change to the delivery model: install still happens via `git clone`.
- No GitHub Releases / Git LFS / fleet image system.
- No cross-arch build matrix. The fleet is **uniform Debian 13 (trixie), aarch64**
  (Zero 2 W, Pi 4, Pi 5 are all ARMv8) — a single committed binary runs on all boards.
- Only `mavlink-routerd` is shipped as a binary; everything else stays `apt install`
  + copy-scripts.
- No module-directory restructure (rejected Approach B) and no single declarative
  installer (rejected Approach C).

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Fleet OS | Uniform Debian 13, aarch64 | One binary covers all boards; no compat gymnastics. |
| Module selection | **Named profiles in repo** | Reproducible, version-controlled, self-documenting fleet variants. |
| Absent hardware at install | **Install fully, enable, tolerate** | Install decoupled from hardware; `Restart=always` self-heals when hardware appears. |
| Orchestration | **Thin orchestrator + existing per-module scripts** (Approach A) | Smallest change; preserves setup/runtime split, env-file config, independently-testable modules. |
| Binary storage | Committed to `bin/` in repo | Rides along with `git clone`; deterministic install (identical bytes on every drone). |

## Architecture

### 1. Repo layout & profile format

New files:

```
profiles/
  full.conf        # wifi, mavlink, camera, cellular, telemetry  (previous behavior)
  scout.conf       # wifi, mavlink, telemetry                    (link + FC + cloud, no camera/cellular)
  bench.conf       # wifi, mavlink                                (minimal bring-up for testing)
bin/
  mavlink-routerd          # prebuilt aarch64 binary (committed)
  mavlink-routerd.version  # provenance: mavlink-router git commit built from
scripts/
  build_mavlink_router.sh  # maintainer tool: regenerates bin/mavlink-routerd (memory-safe)
```

Profile format — newline-delimited module names; `#` comments and blank lines ignored:

```
# profiles/scout.conf — link + flight-controller routing + cloud telemetry
wifi
mavlink
telemetry
```

Canonical module set (fixed, known to the orchestrator): `wifi mavlink camera cellular telemetry`.
A profile is a subset. The orchestrator always runs modules in this **canonical order**
regardless of listing order in the file, because the order encodes a real dependency
(`telemetry-sender.service` has `Requires=mavlink-router.service`, so mavlink installs first).
Profiles are starting points, freely editable to match real drone variants.

### 2. Orchestrator (`install.sh`)

Flow:

1. **Parse args.** `--profile <name>` required. Missing/unknown → print available
   profiles from `profiles/*.conf`, exit non-zero. Also supports `--dry-run` (below).
2. **Read & validate profile.** Strip comments/blanks; validate every name against the
   canonical set. A typo (`camra`) errors immediately — nothing runs.
3. **Run modules in canonical order, isolated.** Capture each module's exit code; the
   loop continues on failure (no global `set -e` in the orchestrator):

   ```bash
   for module in $ORDERED_SELECTION; do
     echo "===== $module ====="
     if sudo env SCRIPT_DIR="$SCRIPT_DIR" bash "scripts/setup_${module}.sh"; then
       results[$module]=OK
     else
       results[$module]=FAILED   # logged, loop CONTINUES
     fi
   done
   ```

4. **Record profile.** Write the chosen profile name to `/etc/specter/installed-profile`
   (single source of truth for what this drone is; used by `update.sh`).
5. **Summary table + honest exit code:**

   ```
   ── Install summary (profile: scout) ─────────────
   module      install   service
   wifi        OK        active
   mavlink     OK        active
   telemetry   OK        inactive   (DRONE_API_KEY unset)
   ─────────────────────────────────────────────────
   ```

   - **install** column = did the setup script succeed (real errors only; absent hardware
     is *not* a failure).
   - **service** column = `systemctl is-active <svc>` per module (cellular has no service —
     it is an nmcli connection — shows `n/a`).
   - **Exit code** non-zero only if a module's *install* FAILED, so CI/automation catches
     genuine breakage while tolerating "camera not plugged in yet."

Module output streams live to the console; the summary is the recap. No separate log file
in v1. An `inactive` service is information, not alarm.

`--dry-run` resolves and prints the module order for a profile without executing (no root,
no hardware). This is where selection/ordering/validation logic is exercised in tests.

### 3. Per-module script contract

Each `setup_<module>.sh` is reshaped around two phases:

**Phase 1 — Install (fatal on error, keep `set -e`):** `apt install`, copy scripts/configs,
`envsubst` templates, `systemctl enable`. Hardware-independent; a failure here is a real
bug → module exits non-zero → orchestrator marks `FAILED`.

**Phase 2 — Activate (non-fatal, explicitly guarded):** `systemctl start`, hardware probes,
connectivity checks. Wrapped (`|| true` / guarded) so absent hardware warns and continues.
The service is already `enable`d with `Restart=always`, so it self-heals when hardware arrives.

Universal rules:

- **Remove the trailing `sudo systemctl status <svc>`** — it returns non-zero for an
  inactive unit and aborts under `set -e`. The orchestrator's summary reports status now.
- **Idempotent** — re-running is always safe (preserve existing `command -v` / `nmcli con show` guards).

Per-script edits:

| Script | Edits |
|---|---|
| `setup_wifi.sh` | Driver guard → **approach C** (`iw list \| grep -q '\* AP'`; build only as fallback). `systemctl start drone-wifi` non-fatal. |
| `setup_mavlink.sh` | Use prebuilt binary (§4); `start` non-fatal; drop fatal `status`. |
| `setup_camera.sh` | `nmcli con add` + `systemctl start camera-relay` non-fatal; drop fatal `status`. |
| `setup_cellular.sh` | `mmcli` PIN unlock and **`nmcli connection up`** non-fatal (hard-fail today with no modem). Profile still created with `autoconnect yes`, so it connects when the modem appears. |
| `setup_telemetry.sh` | Already implements the contract (`DRONE_API_KEY` empty-check). Make the `else`-branch `status` non-fatal. |

Note: `setup_telemetry.sh` is the reference implementation of this contract — it enables the
service but refuses to start it when `DRONE_API_KEY` is empty, precisely to avoid flapping.
We generalize that instinct across all five modules.

### 4. Prebuilt `mavlink-routerd`

**`scripts/build_mavlink_router.sh`** (maintainer tool; not run on drones during normal install):

- Clones mavlink-router, `meson setup build --prefix=/usr`, builds **memory-safely** —
  picks jobs from available RAM (`jobs = max(1, MemAvailable_MB / 400)`, capped at `nproc`),
  so `-j1` on a Zero 2 W and fast on a Pi 5 automatically.
- Copies result to `bin/mavlink-routerd`; writes `bin/mavlink-routerd.version` (source git commit).
- `--install` flag also installs to `/usr/bin/` on the current machine (used by fallback).

**`setup_mavlink.sh` — copy-or-fallback:**

```bash
if [ -x "$SCRIPT_DIR/bin/mavlink-routerd" ]; then
    sudo install -m 755 "$SCRIPT_DIR/bin/mavlink-routerd" /usr/bin/mavlink-routerd
elif ! command -v mavlink-routerd &>/dev/null; then
    echo "No prebuilt binary found — building from source (slow on low-RAM boards)…"
    bash "$SCRIPT_DIR/scripts/build_mavlink_router.sh" --install
fi
```

The common path becomes a file copy — no compiler, no OOM, seconds not minutes.

Cleanups that come with this:

1. **Move the build toolchain out of the hot path.** `meson ninja-build systemd-dev g++ …`
   move from `setup_mavlink.sh` (runs on every drone) into `build_mavlink_router.sh`
   (the only place that compiles). No C++ toolchain on flight hardware.
2. **Fix a latent path mismatch.** `mavlink-router.service` runs `/usr/bin/mavlink-routerd`,
   but a plain `ninja install` uses meson default prefix `/usr/local` → `/usr/local/bin`.
   Standardize on `/usr/bin` (`install -m755` for the binary, `--prefix=/usr` for the
   source fallback) so the service path is correct in both cases.

The source fallback is also the escape hatch if a non-Debian-13 board is ever added: the
committed binary would not match, `command -v` finds nothing, and it builds automatically.

### 5. Backward-compat & testing

**No-arg `install.sh`** now **requires `--profile`** (breaking change vs. today's "runs
everything"). No-arg prints usage + available profiles and exits non-zero. Chosen over
defaulting to `full` because on a fleet, "forgot the flag → silently installed camera+cellular
on a bench drone" is exactly the mistake profiles prevent. README Quick Start updated to match.

**A drone remembers what it is** via `/etc/specter/installed-profile`, written at install.

**`update.sh` becomes profile-aware.** Today it unconditionally copies all service files and
restarts `camera-relay` + `telemetry-sender` — which **fails on a scout drone** with no camera.
New: read `/etc/specter/installed-profile`, update only that profile's modules, restart only
their services.

**Testing — three layers:**

1. **`shellcheck` on every script, in CI** (`.github/`). Catches shell quoting/logic bugs cheaply.
2. **`install.sh --dry-run`** — resolves/prints module order for a profile without executing.
   Exercises profile parsing, validation (typo rejection), and canonical ordering with no
   root or hardware.
3. **On-hardware smoke test** — documented: run `--profile bench` on the Zero 2 W, confirm
   the summary table and `systemctl is-active`. The real acceptance test.

## Success criteria

- `./install.sh --profile scout` installs exactly wifi + mavlink + telemetry; camera and
  cellular artifacts are absent.
- Removing/unplugging a module's hardware never aborts the install of other modules; the
  summary reports it as `inactive`, exit code stays 0.
- A fresh Zero 2 W installs `mavlink` in seconds via the committed binary, with no compile
  and no OOM.
- `./install.sh` with no profile fails clearly and lists available profiles.
- `update.sh` on a scout drone does not touch or restart camera/cellular services.
- `shellcheck` passes on all scripts in CI; `--dry-run` prints correct ordered selection.

## Open items for the implementation plan

- Exact module → service-name map for the summary's `is-active` column
  (wifi→drone-wifi, mavlink→mavlink-router, camera→camera-relay, cellular→n/a,
  telemetry→telemetry-sender).
- Whether `--dry-run` also validates that referenced setup scripts exist.
- Build and commit the first `bin/mavlink-routerd` (run `build_mavlink_router.sh` on a
  Pi 4/5 or the Zero 2 W with `-j1`).
