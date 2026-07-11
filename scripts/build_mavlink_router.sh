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
