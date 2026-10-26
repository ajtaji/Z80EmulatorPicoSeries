# Checks the window against the REAL Windows pointer, without clicking: the
# pointer is put just inside the top-left and bottom-right corners of controls
# at the top, middle and bottom of the window and at its right-hand side, and
# the window (started with --ui-log) must report that control under it and a
# canvas pointer equal to the physical point. The clicks themselves are proved
# by  z80_desktop.exe --pointer-test <file> , which uses no real pointer.
#
# The pointer is shared with everyone on this desktop: the DESKTOP lease is
# held the whole time, the pointer goes back where it was, and a point is
# skipped unless WindowFromPoint there is this window.
# Usage (PowerShell): .\tools\ui_check.ps1 [-Exe desktop\z80_desktop.exe] [-Shot <absolute .png>]
param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\desktop\z80_desktop.exe'),
    [string]$Shot = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class U {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(P p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
}
'@
[U]::SetProcessDPIAware() | Out-Null
. C:\PMFBuild\board-leases\lease.ps1
$lease = Get-BoardLease -Port DESKTOP -Owner 'z80-core' -Minutes 3
$p = $null; $home0 = [Windows.Forms.Cursor]::Position
$log = Join-Path $env:TEMP ("z80ui-" + [guid]::NewGuid().ToString('N') + '.txt')
$fails = 0; $checks = 0; $skips = 0
try {
    $p = Start-Process $Exe -ArgumentList '--ui-log', $log -PassThru
    $deadline = (Get-Date).AddSeconds(20)
    while (((Get-Date) -lt $deadline) -and (!(Test-Path $log) -or $p.MainWindowHandle -eq 0)) { Start-Sleep -Milliseconds 200; $p.Refresh() }
    $h = $p.MainWindowHandle
    [U]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 800

    function Read-Ui {
        $t = ''
        for ($i = 0; $i -lt 20; $i++) {
            try { $t = [IO.File]::ReadAllText($log); if ($t -match 'STATE ') { break } } catch { }
            Start-Sleep -Milliseconds 50
        }
        $r = @{}; $state = @{}; $hover = ''
        foreach ($ln in $t -split "`n") {
            $ln = $ln.Trim()
            if ($ln -match '^RECT (\S+) (\S+) (\S+) (\S+) (\S+)$') { $r[$Matches[1]] = @([double]$Matches[2], [double]$Matches[3], [double]$Matches[4], [double]$Matches[5]) }
            elseif ($ln -match '^HOVER ?(.*)$') { $hover = $Matches[1] }
            elseif ($ln -match '^STATE (.*)$') { foreach ($kv in $Matches[1] -split ' ') { $a = $kv -split '=', 2; if ($a.Count -eq 2) { $state[$a[0]] = $a[1] } } }
        }
        [pscustomobject]@{ Rects = $r; State = $state; Hover = $hover }
    }
    function Origin { $pt = New-Object U+P; [U]::ClientToScreen($h, [ref]$pt) | Out-Null; $pt }
    function Hover-At([string]$name, [string]$where) {
        $ui = Read-Ui
        $key = ($ui.Rects.Keys | Where-Object { $_ -eq $name -or $_ -like "$name`:*" } | Select-Object -First 1)
        $script:checks++
        if (!$key) { $script:fails++; "  FAIL  $name is not drawn"; return }
        $rc = $ui.Rects[$key]
        if ($where -eq 'tl') { $x = [int]($rc[0] + 2); $y = [int]($rc[1] + 2) } else { $x = [int]($rc[0] + $rc[2] - 2); $y = [int]($rc[1] + $rc[3] - 2) }
        $o = Origin
        $sp = New-Object U+P; $sp.X = $o.X + $x; $sp.Y = $o.Y + $y
        if ([U]::GetAncestor([U]::WindowFromPoint($sp), 2) -ne $h) { $script:skips++; "  skip  $key ${where}: another window is on top there"; return }
        [U]::SetCursorPos($sp.X, $sp.Y) | Out-Null
        Start-Sleep -Milliseconds 300
        $ui = Read-Ui
        $hit = (" " + $ui.Hover + " ") -like "* $key *"
        $ok = $hit -and [math]::Abs([double]$ui.State['mx'] - $x) -le 0.5 -and [math]::Abs([double]$ui.State['my'] - $y) -le 0.5
        if ($ok) { "  ok    $key hovered at its $where corner ($x,$y)" }
        else { $script:fails++; "  FAIL  $key $where ($x,$y): read as $($ui.State['mx']),$($ui.State['my']), under it '$($ui.Hover)'" }
    }

    "display scale " + ([U]::GetDpiForWindow($h) / 96.0) + ", window scale " + (Read-Ui).State['scale']
    foreach ($c in 'open', 'speed', 'breakat', 'memtab3', 'memscroll', 'dis0', 'logtab0', 'logtab1', 'logscroll') {
        Hover-At $c 'tl'; Hover-At $c 'br'
    }
    if ($Shot) {
        Hover-At 'runtests' 'br'
        $o = Origin
        $bmp = New-Object Drawing.Bitmap 900, 70
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($o.X, $o.Y, 0, 0, $bmp.Size)
        $c = [Windows.Forms.Cursor]::Position
        [Windows.Forms.Cursors]::Default.Draw($g, (New-Object Drawing.Rectangle ($c.X - $o.X), ($c.Y - $o.Y), 32, 32))
        $g.Dispose(); $bmp.Save($Shot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        "  shot  $Shot"
    }
} finally {
    [U]::SetCursorPos($home0.X, $home0.Y) | Out-Null
    if ($p -and !$p.HasExited) { $p.CloseMainWindow() | Out-Null; if (!$p.WaitForExit(5000)) { $p.Kill() } }
    Remove-Item $log -ErrorAction SilentlyContinue
    Release-BoardLease $lease
}
"real-pointer hover checks=$checks failures=$fails skipped=$skips" + $(if ($fails -eq 0 -and $skips -eq 0) { ' PASS' } else { ' FAIL' })
if ($fails -or $skips) { exit 1 }
