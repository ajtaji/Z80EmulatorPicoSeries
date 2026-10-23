#!/bin/bash
# Usage: tools/board.sh <source> <output.uf2> <seconds> [<source> <output.uf2> <seconds>]...
# Builds every job first (no board), then takes the shared COM7 lease from
# Bash (noclobber create), uploads and captures each job through the
# compiler's own uploader, and removes the lease on exit. Leases are taken
# from Bash only (the PowerShell provider does not see Bash-created leases).
set -u
cd "$(dirname "$0")/.."
LEASE=/c/PMFBuild/board-leases/COM7.lease
ME="z80-core"
JOBS=("$@")
TOTAL=0
for ((k = 0; k < ${#JOBS[@]}; k += 3)); do
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1 -Source "${JOBS[k]}" -Output "${JOBS[k+1]}" | grep -E "ASSEMBLER: [0-9]|image ends|rror|PM[0-9]" || { echo "build failed: ${JOBS[k]}"; exit 1; }
  TOTAL=$((TOTAL + ${JOBS[k+2]} + 40))
done
mkdir -p /c/PMFBuild/board-leases
while true; do
  if ( set -o noclobber; echo "$ME $(date +%Y-%m-%dT%H:%M:%S) expected-until $(date -d "+$TOTAL seconds" +%H:%M:%S) ($(( ${#JOBS[@]} / 3 )) upload+capture jobs)" > "$LEASE" ) 2>/dev/null; then
    break
  fi
  sleep 3
done
trap 'if grep -q "^$ME " "$LEASE" 2>/dev/null; then rm -f "$LEASE"; echo "COM7 lease released"; fi' EXIT
echo "COM7 lease taken $(date +%H:%M:%S)"
for ((k = 0; k < ${#JOBS[@]}; k += 3)); do
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1 -Source "${JOBS[k]}" -Output "${JOBS[k+1]}" -Port COM7 -Seconds "${JOBS[k+2]}" -NoPrecheck
done
