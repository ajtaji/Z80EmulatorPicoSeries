#!/bin/sh
# Builds the desktop Z80 emulator on Linux (x64): z80_desktop (the Neon window) and
# the console programs z80_console, z80_console_untimed, z80_console_procs and
# z80_console_procs_untimed - the same sources as build.ps1 on Windows.
#   PUREBASIC_HOME     PureBasic 6.41+ for Linux (its C back end, compilers/pbcompilerc)
#   NEON_ENGINE_DIR    the Neon Arcade Display Engine (default: a clone beside this repository)
# Build from a Linux file system, not a Windows drive under WSL (/mnt/c): there the
# compiler can include a file twice ("Procedure is already declared").
set -e
here=$(cd "$(dirname "$0")" && pwd)
: "${PUREBASIC_HOME:?set PUREBASIC_HOME to the PureBasic for Linux folder}"
pbc="$PUREBASIC_HOME/compilers/pbcompilerc"
engine=${NEON_ENGINE_DIR:-$here/../../Neon-Arcade-Dispay-Engine}
if [ ! -f "$engine/GlUIChrome.pbi" ]; then
  echo "The Neon Arcade Display Engine is not at $engine. Clone github.com/ajtaji/Neon-Arcade-Dispay-Engine beside this repository, or set NEON_ENGINE_DIR." >&2
  exit 1
fi
engine=$(cd "$engine" && pwd)/
# ZEXDOC/ZEXALL are built in when tools/fetch_zex.py has fetched them.
zex=0
if [ -f "$here/../tests/zex_data.pico" ]; then zex=1; else echo "ZEXDOC/ZEXALL not fetched: building without them (python3 tools/fetch_zex.py adds them)."; fi
python3 "$here/../tools/gen_z80_desktop.py" --check || { echo "desktop/z80core.pbi is stale" >&2; exit 1; }
# The procedure-table builds exist for the dispatch measurement only.
python3 "$here/../tools/gen_z80_desktop_procs.py" > /dev/null
for b in "z80_console 1 0" "z80_console_untimed 0 0" "z80_console_procs 1 1" "z80_console_procs_untimed 0 1"; do
  set -- $b
  "$pbc" "$here/console_main.pb" -cl -t -o "$here/$1" -z \
    -co "GL_ENGINE_DIR\$=$engine" -co "Z80_TIMED=$2" -co "Z80_PROCS=$3" -co "Z80_HAVE_ZEX=$zex"
  [ -f "$here/$1" ] || { echo "Build failed: $1" >&2; exit 1; }
done
"$pbc" "$here/z80_desktop.pb" -t -o "$here/z80_desktop" -z \
  -co "GL_ENGINE_DIR\$=$engine" -co "Z80_HAVE_ZEX=$zex"
[ -f "$here/z80_desktop" ] || { echo "Build failed: z80_desktop" >&2; exit 1; }
sha256sum "$here/z80_desktop" "$here"/z80_console*
