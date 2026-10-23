#!/bin/bash
# Usage: tools/board_until.sh <source> <output.uf2> <max-seconds> <regex> <log>
# Like board.sh for one long job: builds, takes the COM7 lease (Bash, noclobber),
# uploads without the compiler's fixed capture, then reads the port with
# tools/capture.py until a line matches <regex> (the run's verdict) or
# <max-seconds> pass, and releases the lease at once.
set -u
cd "$(dirname "$0")/.."
SRC="$1"; OUT="$2"; MAXS="$3"; RX="$4"; LOG="$5"
LEASE=/c/PMFBuild/board-leases/COM7.lease
ME="z80-core"
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1 -Source "$SRC" -Output "$OUT" | grep -E "ASSEMBLER: [0-9]|image ends|rror|PM[0-9]" || { echo "build failed: $SRC"; exit 1; }
mkdir -p /c/PMFBuild/board-leases
while true; do
  if ( set -o noclobber; echo "$ME $(date +%Y-%m-%dT%H:%M:%S) expected-until $(date -d "+$((MAXS + 90)) seconds" +%H:%M:%S) (long run: $SRC)" > "$LEASE" ) 2>/dev/null; then
    break
  fi
  sleep 3
done
trap 'if grep -q "^$ME " "$LEASE" 2>/dev/null; then rm -f "$LEASE"; echo "COM7 lease released $(date +%H:%M:%S)"; fi' EXIT
echo "COM7 lease taken $(date +%H:%M:%S)"
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1 -Source "$SRC" -Output "$OUT" -Port COM7 -Seconds 0 -NoPrecheck | grep -E "NATIVE UPLOADER\] (Wrote|FLASH)|rror|did not"
py -3 tools/capture.py COM7 "$MAXS" "$RX" "$LOG"
