param(
  [string]$RimeDir = 'D:\rime-sandbox',
  [int]$Runs = 3
)
# Measure the real v -> 1 latency: the time from "the flag file appears" to
# "the settings window is visible on screen".
#
# The IME writes the flag file inside its key handler, so this is essentially the
# user-perceived delay after pressing 1 (minus Weasel's own key handling).
#
# ASCII-only source on purpose: Windows PowerShell 5.1 parses BOM-less UTF-8
# scripts as ANSI, which breaks quoting when non-ASCII characters are present.

$ErrorActionPreference = 'Stop'
$flag = Join-Path $RimeDir 'open-settings.flag'
$guiName = 'vmenu-' + 'settings-gui.ps1'

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class Vw {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

function Get-GuiProcess {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($guiName) -ge 0 } |
    Select-Object -First 1
}

function Get-Visible([int]$procId) {
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $p -or $p.MainWindowHandle -eq 0) { return $false }
  # Visible is not enough: the window must also be on screen (not parked at
  # -32000 like a pre-rendered hidden window).
  $rc = New-Object Vw+RECT
  if (-not [Vw]::GetWindowRect($p.MainWindowHandle, [ref]$rc)) { return $false }
  return ($rc.Left -gt -1000 -and $rc.Top -gt -1000 -and $rc.Right -gt 0 -and $rc.Bottom -gt 0)
}

$gui = Get-GuiProcess
if (-not $gui) { Write-Error 'resident settings window is not running'; exit 2 }
$guiPid = $gui.ProcessId
"gui pid = $guiPid"
"visible now = $(Get-Visible $guiPid)"

$results = @()
for ($i = 1; $i -le $Runs; $i++) {
  # 1) hide the window first
  [IO.File]::WriteAllText($flag, 'hide')
  $t = 0
  while ((Get-Visible $guiPid) -and $t -lt 2000) { Start-Sleep -Milliseconds 10; $t += 10 }
  if (Get-Visible $guiPid) { Write-Error 'window did not hide'; exit 3 }
  Start-Sleep -Milliseconds 150

  # 2) request the window and time how long it takes to become visible
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [IO.File]::WriteAllText($flag, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
  while (-not (Get-Visible $guiPid) -and $sw.ElapsedMilliseconds -lt 5000) {
    Start-Sleep -Milliseconds 5
  }
  $sw.Stop()
  $ms = $sw.ElapsedMilliseconds
  "run ${i}: window visible after $ms ms"
  $results += $ms
}

"---"
"min = $(($results | Measure-Object -Minimum).Minimum) ms"
"max = $(($results | Measure-Object -Maximum).Maximum) ms"
"avg = $([int](($results | Measure-Object -Average).Average)) ms"
