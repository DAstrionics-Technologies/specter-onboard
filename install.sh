#!/bin/bash
# Specter Onboard installer — profile-driven, non-blocking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SPECTER_PROFILES_DIR:-$SCRIPT_DIR/profiles}"

CANONICAL_MODULES=(wifi mavlink camera cellular telemetry health)
declare -A MODULE_SERVICE=(
  [wifi]="drone-wifi"
  [mavlink]="mavlink-router"
  [camera]="camera-relay"
  [cellular]=""
  [telemetry]="telemetry-sender"
  [health]="health-logger"
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

[ "${#SELECTED[@]}" -gt 0 ] || die "profile '$PROFILE' selects no modules"

declare -A RESULT=()
for module in "${SELECTED[@]}"; do
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
for module in "${SELECTED[@]}"; do
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
