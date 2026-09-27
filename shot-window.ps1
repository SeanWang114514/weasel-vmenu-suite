param(
  [Parameter(Mandatory=$true)][string]$Match,
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$Pad = 6
)
# Find a top-level window whose title contains $Match, raise it, and capture its
# exact rectangle as a PNG.
#
# ASCII-only source on purpose (comments included): Windows PowerShell 5.1 parses a
# BOM-less UTF-8 script as ANSI, and mangled multi-byte comment bytes can inject
# quote characters that break the whole parse.
#
# SetProcessDPIAware() MUST run before any GetWindowRect / CopyFromScreen call.
# Without it this process is DPI-unaware, so GetWindowRect returns virtualized
# coordinates (real size / 1.5 on a 150% display) and the capture only covers the
# window's top-left corner - right-hand controls look like they are missing.

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class DpiFix {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
"@
[void][DpiFix]::SetProcessDPIAware()
Start-Sleep -Milliseconds 150

Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class Sw {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static IntPtr Found = IntPtr.Zero;
  public static string Needle = "";
  public static bool Cb(IntPtr h, IntPtr l){
    if(!IsWindowVisible(h)) return true;
    var sb=new StringBuilder(512); GetWindowText(h,sb,512);
    if(sb.ToString().Contains(Needle)) { Found = h; return false; }
    return true;
  }
  public static IntPtr Find(string needle){
    Found = IntPtr.Zero; Needle = needle;
    EnumWindows(Cb, IntPtr.Zero);
    return Found;
  }
  public static void Force(IntPtr h){
    ShowWindow(h, 9);
    uint pid; uint t = GetWindowThreadProcessId(h, out pid);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, t, true);
    BringWindowToTop(h); SetForegroundWindow(h); SetFocus(h);
    AttachThreadInput(cur, t, false);
  }
}
"@

"screen metrics now: $([DpiFix]::GetSystemMetrics(0))x$([DpiFix]::GetSystemMetrics(1))"

$h = [Sw]::Find($Match)
if ($h -eq [IntPtr]::Zero) { "WINDOW_NOT_FOUND: $Match"; exit 2 }
[Sw]::Force($h)
Start-Sleep -Milliseconds 700
$h2 = [Sw]::Find($Match)
if ($h2 -ne [IntPtr]::Zero) { $h = $h2 }

$r = New-Object Sw+RECT
[void][Sw]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
$x = [Math]::Max(0, $r.Left - $Pad)
$y = [Math]::Max(0, $r.Top - $Pad)
$w = [Math]::Min($w + 2 * $Pad, 4000)
$ht = [Math]::Min($ht + 2 * $Pad, 4000)

$bmp = New-Object Drawing.Bitmap $w, $ht
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($x, $y, 0, 0, (New-Object Drawing.Size($w, $ht)))
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"CAPTURED $w x $ht at $x,$y -> $Out"
