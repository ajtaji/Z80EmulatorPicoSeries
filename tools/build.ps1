param(
    [string]$Compiler = 'C:\Users\ajtaj\Desktop\Github\PureBasicCode\OpenGl Work\ArduinoBasic\PureMetalForge.exe',
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$Port = '',
    [int]$Seconds = 12,
    [string[]]$Expect = @(),
    [switch]$NoPrecheck
)
# Builds one program with the PureMetal Forge application. With -Port it
# uploads through the compiler's own uploader and captures the serial output
# for -Seconds; -Expect lists texts the capture must contain (and FAIL must not).
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot $Source))
$outputPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $Output))
[IO.Directory]::CreateDirectory((Split-Path $outputPath -Parent)) | Out-Null
$stdoutPath = $outputPath + '.build.log'
$stderrPath = $outputPath + '.stderr.log'
function Invoke-Forge([string]$extra) {
    $arguments = '--compile "' + $sourcePath + '" -S -o "' + $outputPath + '"' + $extra
    $process = Start-Process -FilePath $Compiler -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Get-Content $stdoutPath | Select-String -NotMatch '^\[DEBUG\]|^> Loaded|^> Intrinsics' | ForEach-Object { $_.Line }
    Get-Content $stderrPath
    if ($process.ExitCode -ne 0) { throw "Compiler exit $($process.ExitCode): $stdoutPath" }
}
# Build first, without the board: the image must end below the NES ROM
# store at flash 0x10050000 before anything is uploaded.
if (!$NoPrecheck) { Invoke-Forge '' }
if ($outputPath.EndsWith('.uf2')) {
    $uf2 = [IO.File]::ReadAllBytes($outputPath); $imageEnd = 0
    for ($o = 0; $o -lt $uf2.Length; $o += 512) {
        $blockEnd = [BitConverter]::ToUInt32($uf2, $o + 12) + [BitConverter]::ToUInt32($uf2, $o + 16)
        if ($blockEnd -gt $imageEnd) { $imageEnd = $blockEnd }
    }
    'image ends at 0x{0:X8}' -f $imageEnd
    if ($imageEnd -gt 0x10050000) { throw ('Image reaches 0x{0:X8}, past the NES ROM store at 0x10050000; not uploaded.' -f $imageEnd) }
}
if ($Port) { if ($Seconds -gt 0) { Invoke-Forge (' --port ' + $Port + ' --seconds ' + $Seconds) } else { Invoke-Forge (' --port ' + $Port) } }
if ($Expect.Count -gt 0) {
    if (!$Port) { throw '-Expect requires -Port: compiling alone proves nothing.' }
    $transcript = Get-Content -Raw $stdoutPath
    foreach ($required in $Expect) {
        if (!$transcript.Contains($required)) { throw "Missing board verdict: $required" }
    }
    if ($transcript -cmatch '\bFAIL\b') { throw "Board reported FAIL: $stdoutPath" }
    'board verdicts present: ' + ($Expect -join ' | ')
}
