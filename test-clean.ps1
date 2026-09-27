# Robust IME test: clean notepad tab + title verification BEFORE screenshot.
# Fixes the Windows-11 Notepad session-restore issue where a stale tab window
# sits on top of the region while keys go to the fresh (focused) window.
# ASCII-only on purpose (PS 5.1 ANSI parsing of BOM-less files).
param(
  [Parameter(Mandatory = $true)][string]$Keys,      # comma-separated: y,a,n,space,j,i,n,g
  [Parameter(Mandatory = $true)][string]$Out,       # screenshot path
  [string]$TitleMatch = '^\*',                      # regex the window title must match after keys
  [int]$ShotX = 40, [int]$ShotY = 40, [int]$ShotW = 1200, [int]$ShotH = 400,
  [switch]$KeepNotepad                             # do not kill notepads on start (reuse window)
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Tg {
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

$VK = @{
  'a'=0x41;'b'=0x42;'c'=0x43;'d'=0x44;'e'=0x45;'f'=0x46;'g'=0x47;'h'=0x48;'i'=0x49;'j'=0x4A;
  'k'=0x4B;'l'=0x4C;'m'=0x4D;'n'=0x4E;'o'=0x4F;'p'=0x50;'q'=0x51;'r'=0x52;'s'=0x53;'t'=0x54;
  'u'=0x55;'v'=0x56;'w'=0x57;'x'=0x58;'y'=0x59;'z'=0x5A;
  '0'=0x30;'1'=0x31;'2'=0x32;'3'=0x33;'4'=0x34;'5'=0x35;'6'=0x36;'7'=0x37;'8'=0x38;'9'=0x39;
  'space'=0x20;'back'=0x08;'enter'=0x0D;'esc'=0x1B
}

function Get-FgTitle {
  $sb = New-Object Text.StringBuilder 256
  [void][Tg]::GetWindowText([Tg]::GetForegroundWindow(), $sb, 256)
  return $sb.ToString()
}

function Tap([string]$name) {
  $n = $name.ToLower()
  $vk = $VK[$n]
  if ($null -eq $vk) { throw "unknown key: $name" }
  $sc = [Tg]::MapVirtualKey([uint32]$vk, 0)
  [Tg]::keybd_event([byte]$vk, [byte]$sc, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 35
  [Tg]::keybd_event([byte]$vk, [byte]$sc, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 65
}

# ---- 1. ensure ONE clean notepad in the foreground ----
if (-not $KeepNotepad) {
  Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 900
  Start-Process notepad
  Start-Sleep -Seconds 3
}
$targetProc = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $targetProc) { Write-Output 'ERR notepad not found'; exit 2 }
$hwnd = $targetProc.MainWindowHandle

[void][Tg]::ShowWindow($hwnd, 9)
[void][Tg]::MoveWindow($hwnd, 60, 40, 1040, 460, $true)
Start-Sleep -Milliseconds 300

$zpid = 0
$fgw = [Tg]::GetForegroundWindow()
$tid1 = [Tg]::GetWindowThreadProcessId($fgw, [ref]$zpid)
$tid2 = [Tg]::GetCurrentThreadId()
[void][Tg]::AttachThreadInput($tid1, $tid2, $true)
[void][Tg]::BringWindowToTop($hwnd)
[void][Tg]::SetForegroundWindow($hwnd)
[void][Tg]::AttachThreadInput($tid1, $tid2, $false)
Start-Sleep -Milliseconds 200
$fgtitle = Get-FgTitle

# session restore may have opened an old tab -> always force a brand-new one
[System.Windows.Forms.SendKeys]::SendWait('^n')
Start-Sleep -Milliseconds 900
$fgtitle = Get-FgTitle
if ($fgtitle -notmatch 'Notepad') { Write-Output "ERR not in notepad after Ctrl+N, title=[$fgtitle]"; exit 2 }
Write-Output "CLEAN=[$fgtitle]"

# click into the text area (fresh tab = same window handle)
$rc = New-Object Tg+RECT
[void][Tg]::GetWindowRect($hwnd, [ref]$rc)
$clickX = [int](($rc.Left + $rc.Right) / 2)
$clickY = [int]($rc.Top + ($rc.Bottom - $rc.Top) * 0.35)
[void][Tg]::SetCursorPos($clickX, $clickY)
Start-Sleep -Milliseconds 120
[Tg]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
[Tg]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 250

# ---- 2. type ----
foreach ($chunk in $Keys.Split(',')) {
  $part = $chunk.Trim()
  if ($part -ne '') { Tap $part }
}
Start-Sleep -Milliseconds 900

# ---- 3. verify title BEFORE shooting (never capture a mismatched frame) ----
$title = Get-FgTitle
Write-Output "AFTER=[$title]"
if ($title -notmatch $TitleMatch) {
  Write-Output "TITLE_MISMATCH expected=/$TitleMatch/ -> skip screenshot"
  exit 3
}

# ---- 4. screenshot ----
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp = New-Object Drawing.Bitmap ([int]$ShotW), ([int]$ShotH)
$g = [Drawing.Graphics]::FromImage($bmp)
$sz = New-Object -TypeName Drawing.Size -ArgumentList @([int]$ShotW, [int]$ShotH)
$g.CopyFromScreen([int]$ShotX, [int]$ShotY, 0, 0, $sz)
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "SHOT=$Out"
