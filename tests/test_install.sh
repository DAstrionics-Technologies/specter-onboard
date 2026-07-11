#!/bin/bash
# Dependency-free dry-run logic tests for install.sh (no root/hardware).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"
fail=0

want_in() { # desc, needle, haystack
  if printf '%s' "$3" | grep -qF "$2"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    echo "  wanted: $2"
    echo "  got:    $3"
    fail=1
  fi
}
want_nonzero() { # desc, cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $desc (expected non-zero exit)"
    fail=1
  else
    echo "PASS: $desc"
  fi
}

want_in "bench selects wifi+mavlink" \
  "modules (canonical order): wifi mavlink" \
  "$(bash "$INSTALL" --profile bench --dry-run)"

want_in "scout ordered wifi mavlink telemetry" \
  "modules (canonical order): wifi mavlink telemetry" \
  "$(bash "$INSTALL" --profile scout --dry-run)"

# Canonical ordering must not depend on file order.
tmp="$(mktemp -d)"
printf 'telemetry\nwifi\nmavlink\n' > "$tmp/reversed.conf"
want_in "out-of-order profile still canonical" \
  "modules (canonical order): wifi mavlink telemetry" \
  "$(SPECTER_PROFILES_DIR="$tmp" bash "$INSTALL" --profile reversed --dry-run)"

printf 'wifi\nbogus\n' > "$tmp/typo.conf"
want_nonzero "typo'd module name rejected" env SPECTER_PROFILES_DIR="$tmp" bash "$INSTALL" --profile typo --dry-run
rm -rf "$tmp"

want_nonzero "unknown profile rejected" bash "$INSTALL" --profile nope --dry-run
want_nonzero "missing --profile rejected" bash "$INSTALL" --dry-run

exit $fail
