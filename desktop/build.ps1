# Builds the desktop Z80 emulator: z80_desktop.exe (the Neon window), and the
# console programs through build_console.ps1 (the suites and benchmarks).
param(
    [string]$Compiler = 'C:\Program Files\PureBasic\Compilers\pbcompilerc.exe',
    [string]$Engine = 'C:/Users/ajtaj/Desktop/Neon-Arcade-Dispay-Engine/'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
& (Join-Path $here 'build_console.ps1') -Compiler $Compiler
$exe = Join-Path $here 'z80_desktop.exe'
& $Compiler (Join-Path $here 'z80_desktop.pb') /EXE $exe /THREAD /DPIAWARE /OPTIMIZER /CONSTANT "GL_ENGINE_DIR$=$Engine"
if ($LASTEXITCODE -ne 0 -or !(Test-Path $exe)) { throw 'Build failed: z80_desktop.exe' }
Get-FileHash -Algorithm SHA256 (Join-Path $here '*.exe') | ForEach-Object { $_.Hash + '  ' + (Split-Path $_.Path -Leaf) }
