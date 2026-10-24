#!/bin/bash
# Usage: tools/zex_chunks.sh <0 = ZEXDOC | 1 = ZEXALL> <first test> <log> [port, default COM6]
# Runs the exerciser on the board in leases of at most 15 minutes (lease.ps1). Each lease
# boots tests <start>..66; a lease that ends inside a test restarts that test
# in the next one. Every test's verdict line lands in <log>.
set -u
cd "$(dirname "$0")/.."
ALL="$1"; START="$2"; LOG="$3"; PORT="${4:-COM6}"
while [ "$START" -lt 67 ]; do
  # COM7 is the Pico W (RP2040); COM6 and COM20 are RP2350 boards.
  if [ "$PORT" = "COM7" ]; then EXT=picow; else EXT=pico2w; fi
  SRC="tests/_zex${ALL}_$START.$EXT"
  sed -e "s/#ZEX_ALL = 0/#ZEX_ALL = $ALL/" -e "s/#ZEX_FIRST = 0/#ZEX_FIRST = $START/" tests/zex.$EXT > "$SRC"
  echo "=== chunk from test $START $(date +%H:%M:%S)" >> "$LOG"
  BEFORE=$(grep -c "ms\]  \(OK\|ERROR\)" "$LOG")
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/board_until.ps1 -Source "$SRC" -Output "build/zex${ALL}_$START.uf2" -Port "$PORT" -MaxSeconds 840 -Pattern "ZEX ok=" -Log "$LOG"
  sleep 120   # let other waiters in after a long run
  AFTER=$(grep -c "ms\]  \(OK\|ERROR\)" "$LOG")
  DONE=$((AFTER - BEFORE))
  if tail -3 "$LOG" | grep -q "ZEX ok="; then break; fi
  if [ "$DONE" -eq 0 ]; then echo "=== no test finished in a lease; stopping" >> "$LOG"; exit 1; fi
  START=$((START + DONE))
done
echo "=== exerciser $ALL finished $(date +%H:%M:%S)" >> "$LOG"
