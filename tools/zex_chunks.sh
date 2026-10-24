#!/bin/bash
# Usage: tools/zex_chunks.sh <0 = ZEXDOC | 1 = ZEXALL> <first test> <log>
# Runs the exerciser on the board in leases of at most 18 minutes. Each lease
# boots tests <start>..66; a lease that ends inside a test restarts that test
# in the next one. Every test's verdict line lands in <log>.
set -u
cd "$(dirname "$0")/.."
ALL="$1"; START="$2"; LOG="$3"
while [ "$START" -lt 67 ]; do
  SRC="tests/_zex${ALL}_$START.picow"
  sed -e "s/#ZEX_ALL = 0/#ZEX_ALL = $ALL/" -e "s/#ZEX_FIRST = 0/#ZEX_FIRST = $START/" tests/zex.picow > "$SRC"
  echo "=== chunk from test $START $(date +%H:%M:%S)" >> "$LOG"
  BEFORE=$(grep -c "ms\]  \(OK\|ERROR\)" "$LOG")
  tools/board_until.sh "$SRC" "build/zex${ALL}_$START.uf2" 1080 "ZEX ok=" "$LOG"
  AFTER=$(grep -c "ms\]  \(OK\|ERROR\)" "$LOG")
  DONE=$((AFTER - BEFORE))
  if tail -3 "$LOG" | grep -q "ZEX ok="; then break; fi
  if [ "$DONE" -eq 0 ]; then echo "=== no test finished in a lease; stopping" >> "$LOG"; exit 1; fi
  START=$((START + DONE))
done
echo "=== exerciser $ALL finished $(date +%H:%M:%S)" >> "$LOG"
