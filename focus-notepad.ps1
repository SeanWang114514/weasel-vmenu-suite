param(
  [string]$ProcessName = 'notepad',
  [int]$X = 80, [int]$Y = 60, [int]$W = 1000, [int]$H = 420,
  [int]$ClickX = 420, [int]$ClickY = 220
)
# ASCII-only source on purpose (Windows PowerShell 5.1 + BOM-less UTF-8 caveat).
# SetForegroundWindow is refused for a background process unless the calling
# thread is attached to the foreground thread's input queue; attach, raise,
# focus, detach. Verified by re-reading GetForegroundWindow afterwards.

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Fg2 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  public static void Force(IntPtr h){
    ShowWindow(h, 9);
    uint pid;
    uint t = GetWindowThreadProcessId(h, out pid);
    uint cur = GetCurrentThreadId();
    AttachThreadInput(cur, t, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    SetFocus(h);
    AttachThreadInput(cur, t, false);
  }
  public static string Title(IntPtr h){
    var sb = new System.Text.StringBuilder(256);
    GetWindowText(h, sb, 256);
    return sb.ToString();
  }
}
"@

$p = Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { "NOT_FOUND"; exit 2 }
$h = $p.MainWindowHandle

[Fg2]::MoveWindow($h, $X, $Y, $W, $H, $true) | Out-Null
Start-Sleep -Milliseconds 250

$ok = $false
for ($i = 0; $i -lt 8; $i++) {
  [Fg2]::Force($h)
  Start-Sleep -Milliseconds 200
  if ([Fg2]::GetForegroundWindow() -eq $h) { $ok = $true; break }
}
"FOCUSED=$ok after $($i) tries"

# click inside the edit area so the caret is there
[Fg2]::SetCursorPos($ClickX, $ClickY) | Out-Null
Start-Sleep -Milliseconds 150
[Fg2]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
[Fg2]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 300

$fg = [Fg2]::GetForegroundWindow()
"FOREGROUND=$([Fg2]::Title($fg))"
if ($fg -ne $h) { exit 1 }
