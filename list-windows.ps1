param([int]$MinWidth = 0)
# List visible top-level windows (DPI-aware) with their rectangle and owner pid.
# ASCII-only source on purpose (PS 5.1 parses BOM-less .ps1 as ANSI).

Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;using System.Collections.Generic;
public class Win {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static List<string> Lines = new List<string>();
  public static int MinW = 0;
  public static bool Cb(IntPtr h, IntPtr l) {
    if (!IsWindowVisible(h)) return true;
    int len = GetWindowTextLength(h);
    if (len <= 0) return true;
    var sb = new StringBuilder(len + 2);
    GetWindowText(h, sb, sb.Capacity);
    RECT r; GetWindowRect(h, out r);
    int w = r.Right - r.Left, ht = r.Bottom - r.Top;
    if (w < MinW) return true;
    uint pid; GetWindowThreadProcessId(h, out pid);
    Lines.Add(string.Format("pid={0,-7} hwnd={1,-10} {2},{3} {4}x{5}  {6}", pid, h.ToInt64(), r.Left, r.Top, w, ht, sb.ToString()));
    return true;
  }
  public static string[] Run(int minW) { MinW = minW; Lines.Clear(); EnumWindows(Cb, IntPtr.Zero); return Lines.ToArray(); }
}
"@
[void][Win]::SetProcessDPIAware()
Start-Sleep -Milliseconds 100
[Win]::Run($MinWidth) | ForEach-Object { $_ }
