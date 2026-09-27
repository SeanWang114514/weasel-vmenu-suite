param(
  [string]$Keys = 'v',
  [string]$Out = 'D:\VibeCoding\输入法\shots\shot.png',
  [int]$X = 40, [int]$Y = 40, [int]$ShotW = 1200, [int]$ShotH = 560,
  [int]$ClickX = 420, [int]$ClickY = 220,
  [switch]$NoFocus
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Wz {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool r);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$VK = @{
  'v'=0x56; 'u'=0x55; 'a'=0x41; 'b'=0x42; 'c'=0x43; 'd'=0x44; 'e'=0x45;
  'f'=0x46; 'g'=0x47; 'h'=0x48; 'i'=0x49; 'j'=0x4A; 'k'=0x4B; 'l'=0x4C; 'm'=0x4D; 'n'=0x4E;
  'o'=0x4F; 'p'=0x50; 'q'=0x51; 'r'=0x52; 's'=0x53; 't'=0x54; 'w'=0x57; 'x'=0x58; 'y'=0x59; 'z'=0x5A;
  '0'=0x30;'1'=0x31;'2'=0x32;'3'=0x33;'4'=0x34;'5'=0x35;'6'=0x36;'7'=0x37;'8'=0x38;'9'=0x39;
  'space'=0x20; 'lwin'=0x5B; 'ctrl'=0x11; 'shift'=0x10; 'alt'=0x12;
  'esc'=0x1B; 'back'=0x08; 'enter'=0x0D; 'grave'=0xC0; 'equals'=0xBB
}
$KEYUP = 0x0002
$EXTENDED = 0x0001
$EXT_KEYS = @('lwin','rwin','left','right','up','down','insert','delete','home','end','pgup','pgdn')

function Tap([string]$name) {
  $vk = $VK[$name]
  if ($null -eq $vk) { throw "unknown key: $name" }
  $sc = [Wz]::MapVirtualKey([uint32]$vk, 0)
  $ext = 0
  if ($EXT_KEYS -contains $name.ToLower()) { $ext = $EXTENDED }
  [Wz]::keybd_event([byte]$vk, [byte]$sc, [uint32]$ext, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [Wz]::keybd_event([byte]$vk, [byte]$sc, [uint32]($ext -bor $KEYUP), [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
}

function Focus-Notepad {
  $p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { return $null }
  $h = $p.MainWindowHandle
  if ($h -eq 0) { return $null }
  [Wz]::MoveWindow($h, 80, 60, 1000, 420, $true) | Out-Null
  Start-Sleep -Milliseconds 200
  [Wz]::ShowWindow($h, 9) | Out-Null
  for ($i = 0; $i -lt 6; $i++) {
    [Wz]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 150
    if ([Wz]::GetForegroundWindow() -eq $h) { break }
  }
  # 用鼠标点击编辑区，确保焦点在文本区（避免按键被菜单加速键吞掉）
  [Wz]::SetCursorPos($ClickX, $ClickY) | Out-Null
  Start-Sleep -Milliseconds 150
  [Wz]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [Wz]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
  return $h
}

if (-not $NoFocus) {
  $h = Focus-Notepad
  if (-not $h) { Write-Error 'notepad not found'; exit 2 }
}

# 支持组合键写法：lwin+space、ctrl+grave
foreach ($chunk in $Keys.Split(',')) {
  $part = $chunk.Trim()
  if ($part -eq '') { continue }
  if ($part.Contains('+')) {
    $names = $part.Split('+')
    foreach ($n in $names[0..($names.Count - 2)]) {
      $nm2 = $n.Trim().ToLower()
      $mvk = [byte]$VK[$nm2]
      $ext = 0
      if ($EXT_KEYS -contains $nm2) { $ext = $EXTENDED }
      [Wz]::keybd_event($mvk, [byte][Wz]::MapVirtualKey([uint32]$mvk, 0), [uint32]$ext, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30
    }
    Tap $names[-1].Trim()
    foreach ($n in $names[0..($names.Count - 2)]) {
      $nm2 = $n.Trim().ToLower()
      $mvk = [byte]$VK[$nm2]
      $ext = 0
      if ($EXT_KEYS -contains $nm2) { $ext = $EXTENDED }
      [Wz]::keybd_event($mvk, [byte][Wz]::MapVirtualKey([uint32]$mvk, 0), [uint32]($ext -bor $KEYUP), [UIntPtr]::Zero); Start-Sleep -Milliseconds 30
    }
  } else {
    Tap $part
  }
}

Start-Sleep -Milliseconds 900

$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp = New-Object Drawing.Bitmap $ShotW, $ShotH
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size($ShotW, $ShotH)))
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

$fg = [Wz]::GetForegroundWindow()
$sb = New-Object Text.StringBuilder 256
[Wz]::GetWindowText($fg, $sb, 256) | Out-Null
$r = New-Object Wz+RECT
[Wz]::GetWindowRect($fg, [ref]$r) | Out-Null
"FOREGROUND=$($sb.ToString())"
$pid2 = 0
$tid = [Wz]::GetWindowThreadProcessId($fg, [ref]$pid2)
$hkl = [Wz]::GetKeyboardLayout($tid)
"HKL=0x$('{0:X8}' -f [int64]$hkl)"
"RECT=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
"SHOT=$Out"
