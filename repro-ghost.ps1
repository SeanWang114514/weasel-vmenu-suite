param(
  [string]$Keys = 's,h,e,n,g,period,h,u',
  [string]$Out = 'D:\VibeCoding\输入法\_tmp-session\repro1.png'
)
# Reproduce candidate-window ghost: type pinyin in notepad, then capture
# the WeaselUIClass window rect + a screenshot while composition is active.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class Wg {
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  public delegate bool EnumProc(IntPtr h, IntPtr lp);
  public static List<string> Found = new List<string>();
  public static IntPtr Match = IntPtr.Zero;
  public static uint Pid = 0;
  public static bool Collect = false;
  public static bool Proc(IntPtr h, IntPtr lp) {
    if (Pid != 0) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != Pid) return true;
    }
    var cls = new StringBuilder(256); GetClassName(h, cls, 256);
    var txt = new StringBuilder(256); GetWindowText(h, txt, 256);
    bool vis = IsWindowVisible(h);
    int ex = GetWindowLong(h, -20);
    string s = h + "|cls=" + cls + "|vis=" + vis + "|extool=" + ((ex & 0x80) != 0) + "|exlay=" + ((ex & 0x80000) != 0) + "|txt=" + txt;
    if (Collect) Found.Add(s);
    // visible layered+toolwindow ATL popup = the weasel candidate panel
    if ((ex & 0x80) != 0 && (ex & 0x80000) != 0 && vis &&
        cls.ToString().StartsWith("ATL:") && Match == IntPtr.Zero)
      Match = h;
    return true;
  }
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

powershell.exe -NoProfile -File 'D:\VibeCoding\输入法\type-and-shot.ps1' -Target notepad -Keys $Keys -Out $Out -ShotX 0 -ShotY 0 -ShotW 1920 -ShotH 1080 | Out-String | Write-Output

$wp = Get-Process | Where-Object { $_.ProcessName -match 'weasel' } | Select-Object -First 1
if ($wp) { "WESELLOBJ=$($wp.Id) $($wp.ProcessName)" }
[Wg]::Collect = $true
[void][Wg]::EnumWindows([Wg+EnumProc]{ param($h,$lp) [Wg]::Proc($h,$lp) }, [IntPtr]::Zero)
[Wg]::Found | ForEach-Object { "WIN=$_" }
$h = [Wg]::Match
if ($h -eq [IntPtr]::Zero) { Write-Output 'PANEL=notfound'; exit 1 }
$rc = New-Object Wg+RECT
[void][Wg]::GetWindowRect($h, [ref]$rc)
$cr = New-Object Wg+RECT
[void][Wg]::GetClientRect($h, [ref]$cr)
"VISIBLE=$([Wg]::IsWindowVisible($h))"
"WINRECT=$($rc.Left),$($rc.Top),$($rc.Right),$($rc.Bottom)"
"CLIENT=$($cr.Left),$($cr.Top),$($cr.Right),$($cr.Bottom)"
