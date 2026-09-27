param(
  [Parameter(Mandatory=$true)][string]$Match,
  [string]$Keys = '',
  [string]$Out = '',
  [int]$Pad = 6,
  [int]$WaitMs = 500
)
# Find a top-level window by title substring, force it to the foreground, send a
# few keys (e.g. "ctrl+tab"), then optionally capture its rectangle.
# DPI-aware: SetProcessDPIAware() must run before GetWindowRect / CopyFromScreen.
# ASCII-only source on purpose (PS 5.1 parses BOM-less .ps1 as ANSI).

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class Wk {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static IntPtr Found = IntPtr.Zero;
  public static string Needle = "";
  public static bool Cb(IntPtr h, IntPtr l) {
    if (!IsWindowVisible(h)) return true;
    var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
    if (sb.ToString().Contains(Needle)) { Found = h; return false; }
    return true;
  }
  public static IntPtr Find(string needle) { Found = IntPtr.Zero; Needle = needle; EnumWindows(Cb, IntPtr.Zero); return Found; }
  public static void Force(IntPtr h) {
    ShowWindow(h, 9);
    uint pid; uint t = GetWindowThreadProcessId(h, out pid);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, t, true);
    BringWindowToTop(h); SetForegroundWindow(h); SetFocus(h);
    AttachThreadInput(cur, t, false);
  }
}
"@
[void][Wk]::SetProcessDPIAware()
Start-Sleep -Milliseconds 120

$h = [Wk]::Find($Match)
if ($h -eq [IntPtr]::Zero) { "WINDOW_NOT_FOUND: $Match"; exit 2 }
[Wk]::Force($h)
Start-Sleep -Milliseconds 300
if ([Wk]::GetForegroundWindow() -ne $h) {
  # ALT trick: unlocks the foreground lock so SetForegroundWindow is allowed
  [Wk]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
  [Wk]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
  [Wk]::Force($h)
  Start-Sleep -Milliseconds 200
}
"FOREGROUND_OK=$([Wk]::GetForegroundWindow() -eq $h)"
$h2 = [Wk]::Find($Match)
if ($h2 -ne [IntPtr]::Zero) { $h = $h2 }

if ($Keys -ne '') {
  $VK = @{ 'ctrl'=0x11; 'shift'=0x10; 'alt'=0x12; 'tab'=0x09; 'esc'=0x1B; 'enter'=0x0D; 'space'=0x20;
           'left'=0x25; 'up'=0x26; 'right'=0x27; 'down'=0x28 }
  foreach ($chunk in $Keys.Split(',')) {
    $names = $chunk.Trim().Split('+')
    $mods = @()
    foreach ($n in $names[0..([Math]::Max(0, $names.Count - 2))]) {
      if ($names.Count -gt 1) { $mods += [byte]$VK[$n.Trim().ToLower()] }
    }
    $last = $names[-1].Trim().ToLower()
    $vk = [byte]$VK[$last]
    foreach ($m in $mods) { [Wk]::keybd_event($m, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
    [Wk]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    [Wk]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    foreach ($m in $mods) { [Wk]::keybd_event($m, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
  }
}

Start-Sleep -Milliseconds $WaitMs

if ($Out -ne '') {
  $r = New-Object Wk+RECT
  [void][Wk]::GetWindowRect($h, [ref]$r)
  $w = [Math]::Min($r.Right - $r.Left + 2 * $Pad, 4000)
  $ht = [Math]::Min($r.Bottom - $r.Top + 2 * $Pad, 4000)
  $x = [Math]::Max(0, $r.Left - $Pad)
  $y = [Math]::Max(0, $r.Top - $Pad)
  $bmp = New-Object Drawing.Bitmap $w, $ht
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object Drawing.Size($w, $ht)))
  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "CAPTURED $w x $ht at $x,$y -> $Out"
}
