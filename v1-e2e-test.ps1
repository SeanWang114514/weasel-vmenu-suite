param(
  [string]$RimeDir = 'D:\rime-sandbox',
  [string]$Target = 'notepad',
  [string]$Out = 'D:\VibeCoding\输入法\shots\v1-e2e.png',
  [int]$ShotX = 40, [int]$ShotY = 40, [int]$ShotW = 1200, [int]$ShotH = 560
)
# End-to-end check of the  v -> 1  shortcut:
#   focus an editor, hide the settings window, press v, press 1, and measure how
#   long it takes until the settings window is visible again.
# ASCII-only source on purpose (PS 5.1 parses BOM-less .ps1 as ANSI).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class E2E {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$flag = Join-Path $RimeDir 'open-settings.flag'
$guiName = 'vmenu-' + 'settings-gui.ps1'

function Get-FgTitle {
  $sb = New-Object Text.StringBuilder 256
  [void][E2E]::GetWindowText([E2E]::GetForegroundWindow(), $sb, 256)
  return $sb.ToString()
}

function Tap([byte]$vk) {
  $sc = [E2E]::MapVirtualKey([uint32]$vk, 0)
  [E2E]::keybd_event($vk, [byte]$sc, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 35
  [E2E]::keybd_event($vk, [byte]$sc, 2, [UIntPtr]::Zero)
}

# --- resident settings window process ---
$gui = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($guiName) -ge 0 } |
  Select-Object -First 1
if (-not $gui) { Write-Error 'resident settings window is not running'; exit 2 }
$guiPid = $gui.ProcessId

function Get-Visible {
  $p = Get-Process -Id $guiPid -ErrorAction SilentlyContinue
  if (-not $p -or $p.MainWindowHandle -eq 0) { return $false }
  # Visible is not enough: the window must also be on screen (not parked at
  # -32000 like a pre-rendered hidden window).
  $rc = New-Object E2E+RECT
  if (-not [E2E]::GetWindowRect($p.MainWindowHandle, [ref]$rc)) { return $false }
  return ($rc.Left -gt -1000 -and $rc.Top -gt -1000 -and $rc.Right -gt 0 -and $rc.Bottom -gt 0)
}

# --- focus the editor ---
$targetProc = Get-Process $Target -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $targetProc) { Write-Error "target $Target not found"; exit 2 }
$hwnd = $targetProc.MainWindowHandle
[void][E2E]::ShowWindow($hwnd, 9)
[void][E2E]::MoveWindow($hwnd, 60, 40, 1040, 460, $true)
Start-Sleep -Milliseconds 250
$zpid = 0
$tid1 = [E2E]::GetWindowThreadProcessId([E2E]::GetForegroundWindow(), [ref]$zpid)
$tid2 = [E2E]::GetCurrentThreadId()
[void][E2E]::AttachThreadInput($tid1, $tid2, $true)
[void][E2E]::BringWindowToTop($hwnd)
[void][E2E]::SetForegroundWindow($hwnd)
[void][E2E]::AttachThreadInput($tid1, $tid2, $false)
if ((Get-FgTitle) -ne $targetProc.MainWindowTitle) {
  [E2E]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
  [E2E]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
  [void][E2E]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 120
}
"FOCUSED=$(Get-FgTitle)"
$rc = New-Object E2E+RECT
[void][E2E]::GetWindowRect($hwnd, [ref]$rc)
[void][E2E]::SetCursorPos([int](($rc.Left + $rc.Right) / 2), [int]($rc.Top + ($rc.Bottom - $rc.Top) * 0.35))
Start-Sleep -Milliseconds 120
[E2E]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
[E2E]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 250

# --- make sure the settings window starts hidden ---
[IO.File]::WriteAllText($flag, 'hide')
$t = 0
while ((Get-Visible) -and $t -lt 2000) { Start-Sleep -Milliseconds 10; $t += 10 }
"hidden before test = $(-not (Get-Visible))"
Start-Sleep -Milliseconds 200

# --- press v (0x56) then 1 (0x31) ---
Tap 0x56
Start-Sleep -Milliseconds 300
$sw = [Diagnostics.Stopwatch]::StartNew()
Tap 0x31
while (-not (Get-Visible) -and $sw.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 5 }
$sw.Stop()
"v then 1 : settings window visible after $($sw.ElapsedMilliseconds) ms"
"flag consumed = $(-not (Test-Path -LiteralPath $flag))"

Start-Sleep -Milliseconds 300
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp = New-Object Drawing.Bitmap ([int]$ShotW), ([int]$ShotH)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen([int]$ShotX, [int]$ShotY, 0, 0, (New-Object Drawing.Size([int]$ShotW, [int]$ShotH)))
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"SHOT=$Out"
