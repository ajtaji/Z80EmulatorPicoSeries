param(
    [Parameter(Mandatory = $true)][string[]]$Jobs,   # "source|output.uf2|seconds", one per job
    [string]$Port = 'COM7',
    [int]$Minutes = 10
)
# Builds every job first (no board), then takes the shared board lease through
# a shared-bench lease script when one is configured (BOARD_LEASE_SCRIPT), uploads
# and captures each job with
# the compiler's own uploader, and gives the lease back.
$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build.ps1'
foreach ($j in $Jobs) { $s, $o, $t = $j.Split('|'); & $build -Source $s -Output $o | Select-String 'ASSEMBLER: [0-9]|image ends' }
# A bench where several people share boards keeps a lease script; without one
# (one board, one person) the board is simply used.
$leaseScript = if ($env:BOARD_LEASE_SCRIPT) { $env:BOARD_LEASE_SCRIPT } else { 'C:\PMFBuild\board-leases\lease.ps1' }
if (Test-Path $leaseScript) { . $leaseScript } else {
    function Get-BoardLease { param($Port, $Owner, $Minutes) return $null }
    function Release-BoardLease($Lease) { }
}
$l = Get-BoardLease -Port $Port -Owner 'z80-core' -Minutes $Minutes
try {
    foreach ($j in $Jobs) { $s, $o, $t = $j.Split('|'); & $build -Source $s -Output $o -Port $Port -Seconds ([int]$t) -NoPrecheck }
} finally { Release-BoardLease $l }
