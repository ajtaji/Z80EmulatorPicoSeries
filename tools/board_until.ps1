param(
    [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Output,
    [string]$Port = 'COM6', [int]$MaxSeconds = 840,
    [Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][string]$Log
)
# One long job: build, take the lease through lease.ps1, upload without the
# compiler's fixed capture, read the port with tools/capture.py until a line
# matches -Pattern or -MaxSeconds pass, give the lease back.
$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build.ps1'
& $build -Source $Source -Output $Output | Select-String 'ASSEMBLER: [0-9]|image ends'
# A bench where several people share boards keeps a lease script; without one
# (one board, one person) the board is simply used.
$leaseScript = if ($env:BOARD_LEASE_SCRIPT) { $env:BOARD_LEASE_SCRIPT } else { 'C:\PMFBuild\board-leases\lease.ps1' }
if (Test-Path $leaseScript) { . $leaseScript } else {
    function Get-BoardLease { param($Port, $Owner, $Minutes) return $null }
    function Release-BoardLease($Lease) { }
}
$l = Get-BoardLease -Port $Port -Owner 'z80-core' -Minutes ([math]::Ceiling(($MaxSeconds + 90) / 60))
try {
    & $build -Source $Source -Output $Output -Port $Port -Seconds 0 -NoPrecheck | Select-String 'Wrote|FLASH|rror|did not'
    py -3 (Join-Path $PSScriptRoot 'capture.py') $Port $MaxSeconds $Pattern $Log
} finally { Release-BoardLease $l }
