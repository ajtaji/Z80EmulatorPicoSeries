param(
    [Parameter(Mandatory = $true)][string[]]$Jobs,   # "source|output.uf2|seconds", one per job
    [string]$Port = 'COM7',
    [int]$Minutes = 10
)
# Builds every job first (no board), then takes the shared board lease through
# C:\PMFBuild\board-leases\lease.ps1 (fair queue; COM7 refuses runs over 15
# minutes - long runs go to COM6 or COM20), uploads and captures each job with
# the compiler's own uploader, and gives the lease back.
$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build.ps1'
foreach ($j in $Jobs) { $s, $o, $t = $j.Split('|'); & $build -Source $s -Output $o | Select-String 'ASSEMBLER: [0-9]|image ends' }
. C:\PMFBuild\board-leases\lease.ps1
$l = Get-BoardLease -Port $Port -Owner 'z80-core' -Minutes $Minutes
try {
    foreach ($j in $Jobs) { $s, $o, $t = $j.Split('|'); & $build -Source $s -Output $o -Port $Port -Seconds ([int]$t) -NoPrecheck }
} finally { Release-BoardLease $l }
