# Builds the console programs: z80_console.exe (timed), z80_console_untimed.exe, and the
# procedure-table pair z80_console_procs*.exe used to measure the dispatch.
#   -Compiler  PureBasic's C-back-end compiler (pbcompilerc.exe)
#   -Engine    the Neon Arcade Display Engine folder (its clock, GL_Micros; default:
#              NEON_ENGINE_DIR, else a clone beside this repository)
param(
    [string]$Compiler = 'C:\Program Files\PureBasic\Compilers\pbcompilerc.exe',
    [string]$Engine = $env:NEON_ENGINE_DIR
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (!$Engine) { $Engine = Join-Path $here '..\..\Neon-Arcade-Dispay-Engine' }
if (!(Test-Path (Join-Path $Engine 'GlUtilities.pbi'))) {
    throw "The Neon Arcade Display Engine is not at $Engine. Clone github.com/ajtaji/Neon-Arcade-Dispay-Engine beside this repository, or pass -Engine / set NEON_ENGINE_DIR."
}
$Engine = (Resolve-Path $Engine).Path.Replace('\', '/').TrimEnd('/') + '/'
# ZEXDOC/ZEXALL are built in when tools/fetch_zex.py has fetched them.
$zex = if (Test-Path (Join-Path $here '..\tests\zex_data.pico')) { '1' } else { '0' }
if ($zex -eq '0') { 'ZEXDOC/ZEXALL not fetched: building without them (py -3 tools\fetch_zex.py adds them).' }
py -3 (Join-Path $here '..\tools\gen_z80_desktop.py') --check
if ($LASTEXITCODE -ne 0) { throw 'desktop/z80core.pbi is stale' }
# The procedure-table builds exist for the dispatch measurement only.
py -3 (Join-Path $here '..\tools\gen_z80_desktop_procs.py') | Out-Null
foreach ($b in @(@('z80_console.exe', '1', '0'), @('z80_console_untimed.exe', '0', '0'),
                 @('z80_console_procs.exe', '1', '1'), @('z80_console_procs_untimed.exe', '0', '1'))) {
    $exe = Join-Path $here $b[0]
    & $Compiler (Join-Path $here 'console_main.pb') /CONSOLE /EXE $exe /THREAD /OPTIMIZER /CONSTANT "GL_ENGINE_DIR$=$Engine" /CONSTANT "Z80_TIMED=$($b[1])" /CONSTANT "Z80_PROCS=$($b[2])" /CONSTANT "Z80_HAVE_ZEX=$zex"
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $exe)) { throw "Build failed: $($b[0])" }
}
