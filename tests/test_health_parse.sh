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
