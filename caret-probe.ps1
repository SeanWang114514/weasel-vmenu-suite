param(
  [string]$Target = 'notepad',
  [string]$Keys = '',
  [string]$Out = 'D:\VibeCoding\输入法\shots\probe.png',
  [int]$ShotX = 40, [int]$ShotY = 30, [int]$ShotW = 1000, [int]$ShotH = 420,
  [switch]$NoClear,
  [switch]$NoShot
)
# Focused IME caret probe: clear the document (ctrl+a, back), then send a key
# sequence (comma separated, "+" for chords, arrows supported), then screenshot.
# ASCII-only source on purpose: PS 5.1 parses BOM-less UTF-8 as ANSI.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Cp {
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
  'space'=0x20;'back'=0x08;'enter'=0x0D;'esc'=0x1B;'tab'=0x09;'delete'=0x2E;'home'=0x24;'end'=0x23;
  'up'=0x26;'down'=0x28;'left'=0x25;'right'=0x27;'pgup'=0x21;'pgdn'=0x22;
  'ctrl'=0x11;'shift'=0x10;'alt'=0x12;'lwin'=0x5B
}
$ExtKeys = @('up','down','left','right','home','end','pgup','pgdn','delete')

function Tap([string]$name) {
  $n = $name.ToLower().Trim()
  $vk = $VK[$n]
  if ($null -eq $vk) { throw "unknown key: $name" }
  $sc = [Cp]::MapVirtualKey([uint32]$vk, 0)
  $ext = 0
  if ($ExtKeys -contains $n) { $ext = 1 }
  [Cp]::keybd_event([byte]$vk, [byte]$sc, $ext, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 35
  [Cp]::keybd_event([byte]$vk, [byte]$sc, ($ext -bor 2), [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
}

function Chord([string]$spec) {
  $names = $spec.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  $mods = @()
  for ($i = 0; $i -lt $names.Count - 1; $i++) { $mods += $names[$i] }
  foreach ($m in $mods) {
    $mvk = $VK[$m.ToLower()]
    $msc = [Cp]::MapVirtualKey([uint32]$mvk, 0)
    $mext = 0; if ($ExtKeys -contains $m.ToLower()) { $mext = 1 }
    [Cp]::keybd_event([byte]$mvk, [byte]$msc, $mext, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
  }
  Tap $names[-1]
  for ($i = $mods.Count - 1; $i -ge 0; $i--) {
    $m = $mods[$i]
    $mvk = $VK[$m.ToLower()]
    $msc = [Cp]::MapVirtualKey([uint32]$mvk, 0)
    $mext = 0; if ($ExtKeys -contains $m.ToLower()) { $mext = 1 }
    [Cp]::keybd_event([byte]$mvk, [byte]$msc, ($mext -bor 2), [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
  }
}

$targetProc = Get-Process $Target -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $targetProc) { Write-Error "target $Target not found"; exit 2 }
$hwnd = $targetProc.MainWindowHandle
[void][Cp]::ShowWindow($hwnd, 9)
[void][Cp]::MoveWindow($hwnd, 60, 30, 900, 400, $true)
Start-Sleep -Milliseconds 250

$zpid = 0
$fgw = [Cp]::GetForegroundWindow()
$tid1 = [Cp]::GetWindowThreadProcessId($fgw, [ref]$zpid)
$tid2 = [Cp]::GetCurrentThreadId()
[void][Cp]::AttachThreadInput($tid1, $tid2, $true)
[void][Cp]::BringWindowToTop($hwnd)
[void][Cp]::SetForegroundWindow($hwnd)
[void][Cp]::AttachThreadInput($tid1, $tid2, $false)
Start-Sleep -Milliseconds 150

# guard: never send keys unless the target really owns the foreground
for ($i = 0; $i -lt 6; $i++) {
  if ([Cp]::GetForegroundWindow() -eq $hwnd) { break }
  [Cp]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
  [Cp]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
  [void][Cp]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 200
}
if ([Cp]::GetForegroundWindow() -ne $hwnd) { 'FOCUS_FAILED'; exit 3 }
"FOREGROUND_OK"

# click into the edit area (also dismisses any live composition)
$rc = New-Object Cp+RECT
[void][Cp]::GetWindowRect($hwnd, [ref]$rc)
$cx = [int](($rc.Left + $rc.Right) / 2)
$cy = [int]($rc.Top + ($rc.Bottom - $rc.Top) * 0.4)
[void][Cp]::SetCursorPos($cx, $cy)
Start-Sleep -Milliseconds 120
[Cp]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
[Cp]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 250

if ([Cp]::GetForegroundWindow() -ne $hwnd) {
  [void][Cp]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 300
}
if ([Cp]::GetForegroundWindow() -ne $hwnd) { 'FOCUS_FAILED_AFTER_CLICK'; exit 3 }

if (-not $NoClear) { Chord 'ctrl+a'; Tap 'back'; Start-Sleep -Milliseconds 200 }

foreach ($chunk in $Keys.Split(',')) {
  $part = $chunk.Trim()
  if ($part -ne '') { Chord $part }
}
Start-Sleep -Milliseconds 700

$sb = New-Object Text.StringBuilder 512
[void][Cp]::GetWindowText([Cp]::GetForegroundWindow(), $sb, 512)
"TITLE=$($sb.ToString())"

if (-not $NoShot) {
  $dir = Split-Path -Parent $Out
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp = New-Object Drawing.Bitmap ([int]$ShotW), ([int]$ShotH)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen([int]$ShotX, [int]$ShotY, 0, 0, (New-Object Drawing.Size([int]$ShotW), ([int]$ShotH)))
  $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "SHOT=$Out"
}
