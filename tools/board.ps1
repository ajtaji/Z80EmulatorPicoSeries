param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Output,
    [int]$Seconds = 30,
    [string[]]$Expect = @(),
    [string]$Session = 'z80-core'
)
# Takes the shared COM7 lease, builds/uploads/captures with build.ps1, and
# releases the lease at once. A lease older than 30 minutes is reported, not
# removed silently.
$ErrorActionPreference = 'Stop'
$leaseDir = 'C:\PMFBuild\board-leases'
$lease = Join-Path $leaseDir 'COM7.lease'
[IO.Directory]::CreateDirectory($leaseDir) | Out-Null
$taken = $false
while (-not $taken) {
    try {
        $fs = [IO.File]::Open($lease, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $until = (Get-Date).AddSeconds($Seconds + 90).ToString('HH:mm:ss')
        $bytes = [Text.Encoding]::ASCII.GetBytes("$Session $(Get-Date -Format s) expected-until $until`r`n")
        $fs.Write($bytes, 0, $bytes.Length); $fs.Close(); $taken = $true
    } catch {
        if ([IO.File]::Exists($lease)) {
            $age = (Get-Date) - [IO.File]::GetLastWriteTime($lease)
            "COM7 lease held: $([IO.File]::ReadAllText($lease).Trim()) (age $([int]$age.TotalMinutes) min); waiting"
            Start-Sleep -Seconds 30
        }
    }
}
try {
    & (Join-Path $PSScriptRoot 'build.ps1') -Source $Source -Output $Output -Port COM7 -Seconds $Seconds -Expect $Expect
} finally {
    # Release only our own lease (System.IO: the PowerShell provider does not
    # always see this folder from a sandboxed shell).
    if ([IO.File]::Exists($lease) -and [IO.File]::ReadAllText($lease).StartsWith($Session + ' ')) {
        [IO.File]::Delete($lease)
        'COM7 lease released'
    } else {
        'COM7 lease was not ours or already gone - nothing deleted'
    }
}
