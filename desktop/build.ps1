# Builds the desktop Z80 emulator: z80_desktop.exe (the Neon window), and the
# console programs through build_console.ps1 (the suites and benchmarks).
#   -Compiler  PureBasic's C-back-end compiler (pbcompilerc.exe)
#   -Engine    the Neon Arcade Display Engine folder (default: NEON_ENGINE_DIR, else a
#              clone beside this repository, ..\Neon-Arcade-Dispay-Engine)
param(
    [string]$Compiler = 'C:\Program Files\PureBasic\Compilers\pbcompilerc.exe',
    [string]$Engine = $env:NEON_ENGINE_DIR
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (!$Engine) { $Engine = Join-Path $here '..\..\Neon-Arcade-Dispay-Engine' }
if (!(Test-Path (Join-Path $Engine 'GlUIChrome.pbi'))) {
    throw "The Neon Arcade Display Engine is not at $Engine. Clone github.com/ajtaji/Neon-Arcade-Dispay-Engine beside this repository, or pass -Engine / set NEON_ENGINE_DIR."
}
$Engine = (Resolve-Path $Engine).Path.Replace('\', '/').TrimEnd('/') + '/'
if (!(Test-Path $Compiler)) { throw "PureBasic's pbcompilerc.exe is not at ${Compiler}: pass -Compiler." }
& (Join-Path $here 'build_console.ps1') -Compiler $Compiler
$exe = Join-Path $here 'z80_desktop.exe'
& $Compiler (Join-Path $here 'z80_desktop.pb') /EXE $exe /THREAD /DPIAWARE /OPTIMIZER /CONSTANT "GL_ENGINE_DIR$=$Engine"
if ($LASTEXITCODE -ne 0 -or !(Test-Path $exe)) { throw 'Build failed: z80_desktop.exe' }
Get-FileHash -Algorithm SHA256 (Join-Path $here '*.exe') | ForEach-Object { $_.Hash + '  ' + (Split-Path $_.Path -Leaf) }
