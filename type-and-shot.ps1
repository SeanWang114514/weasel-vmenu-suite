param(
  [string]$Target = 'notepad',
  [string]$Keys = 'w,s,l',
  [string]$Out = 'D:\VibeCoding\输入法\shots\shot.png',
  [int]$ShotX = 40, [int]$ShotY = 40, [int]$ShotW = 1200, [int]$ShotH = 560,
  [switch]$NoClick
)
# Focus a target window reliably (AttachThreadInput + ALT unlock), send keys, screenshot.
# ASCII only on purpose: a BOM-less .ps1 with Chinese comments parses as ANSI on PS 5.1.

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
  'space'=0x20;'back'=0x08;'enter'=0x0D;'esc'=0x1B;'grave'=0xC0;'equals'=0xBB;'minus'=0xBD;'period'=0xBE;'slash'=0xBF;
  'up'=0x26;'down'=0x28;'left'=0x25;'right'=0x27;'home'=0x24;'end'=0x23;'pgup'=0x21;'pgdn'=0x22;
  'tab'=0x09;'ins'=0x2D;'del'=0x2E;
  'ctrl'=0x11;'shift'=0x10;'alt'=0x12
}
# Arrow / nav keys are "extended" keys: without KEYEVENTF_EXTENDEDKEY some apps
# read them as the numpad equivalents.
$VKExt = @('up','down','left','right','home','end','pgup','pgdn','ins','del')

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
  $ext = 0
  if ($VKExt -contains $n) { $ext = 1 }
  [Tg]::keybd_event([byte]$vk, [byte]$sc, $ext, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 35
  [Tg]::keybd_event([byte]$vk, [byte]$sc, ($ext -bor 2), [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 65
}

$targetProc = Get-Process $Target -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $targetProc) { Write-Error "target $Target not found"; exit 2 }
$hwnd = $targetProc.MainWindowHandle

[void][Tg]::ShowWindow($hwnd, 9)
[void][Tg]::MoveWindow($hwnd, 60, 40, 1040, 460, $true)
Start-Sleep -Milliseconds 250

$zpid = 0
$fgw = [Tg]::GetForegroundWindow()
$tid1 = [Tg]::GetWindowThreadProcessId($fgw, [ref]$zpid)
$tid2 = [Tg]::GetCurrentThreadId()
[void][Tg]::AttachThreadInput($tid1, $tid2, $true)
[void][Tg]::BringWindowToTop($hwnd)
[void][Tg]::SetForegroundWindow($hwnd)
[void][Tg]::AttachThreadInput($tid1, $tid2, $false)

if ((Get-FgTitle) -ne $targetProc.MainWindowTitle) {
  # ALT trick: unlocks the foreground lock so SetForegroundWindow is allowed
  [Tg]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [Tg]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [void][Tg]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 120
}
"FOCUSED=$(Get-FgTitle)"

if (-not $NoClick) {
  $rc = New-Object Tg+RECT
  [void][Tg]::GetWindowRect($hwnd, [ref]$rc)
  $clickX = [int](($rc.Left + $rc.Right) / 2)
  $clickY = [int]($rc.Top + ($rc.Bottom - $rc.Top) * 0.35)
  [void][Tg]::SetCursorPos($clickX, $clickY)
  Start-Sleep -Milliseconds 120
  [Tg]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [Tg]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}

foreach ($chunk in $Keys.Split(',')) {
  $part = $chunk.Trim()
  if ($part -ne '') { Tap $part }
}

Start-Sleep -Milliseconds 800

$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp = New-Object Drawing.Bitmap ([int]$ShotW), ([int]$ShotH)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen([int]$ShotX, [int]$ShotY, 0, 0, (New-Object Drawing.Size([int]$ShotW, [int]$ShotH)))
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

"AFTER=$(Get-FgTitle)"
"SHOT=$Out"
