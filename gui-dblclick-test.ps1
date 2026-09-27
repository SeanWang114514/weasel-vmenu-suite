# =====================================================================
#  gui-dblclick-test.ps1 — 验证设置窗口的「双击所选条目 → 弹框编辑」
#
#  为什么要这么写（踩过的坑）：
#    · UIA 看不到这个 WinForms 窗口的子控件（FindAll 返回 0 个元素），
#      所以改用「截图 + 找文本行 + 真实鼠标双击」。
#    · PowerShell 默认是 DPI-unaware：在 150% 缩放下 SetCursorPos 的坐标
#      会被系统按 1.5 倍缩放，点到的行会整体偏下。必须先 SetProcessDPIAware()。
#    · 弹框是模态窗口，不会出现在 Process.MainWindowTitle 里；找它必须用
#      EnumWindows 枚举顶层窗口标题。
#
#  用法示例：
#    powershell -File gui-dblclick-test.ps1 -Row 1                  # 剪贴板页第 1 行
#    powershell -File gui-dblclick-test.ps1 -PreX 300 -PreY 200 -Row 1    # 先点标签页
#    powershell -File gui-dblclick-test.ps1 -Row 1 -TypeInto test   # 弹框里输入并回车
#
#  实测几何（150% 缩放、窗口 1464x989）：列表表头 y≈176..206，数据行 30px 一行，
#    第 1 行中心 y≈210、第 2 行 ≈240、第 3 行 ≈270 …… 所以默认 ListTop=200 跳过表头。
#  退出码：0 = 弹框如期出现（或 -DryRun 正常完成）；1 = 失败；2 = 找不到窗口
# =====================================================================
param(
  [string]$Match = '小狼毫 v 功能',
  [int]$Row = 1,
  [int]$ListTop = 200,
  [int]$ListLeft = 150,
  [int]$ListRight = 1400,
  [int]$ListBottom = 800,
  [string]$Expect = '编辑第',
  [int]$PreX = -1,
  [int]$PreY = -1,
  [string]$TypeInto = '',
  [string]$Out = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class VmWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  public static string Title(IntPtr h) { var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512); return sb.ToString(); }
  public static IntPtr Find(string sub) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (found == IntPtr.Zero && IsWindowVisible(h)) {
        string t = Title(h);
        if (t.IndexOf(sub, StringComparison.Ordinal) >= 0) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string[] Titles() {
    List<string> list = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (IsWindowVisible(h)) { string t = Title(h); if (t.Length > 0) list.Add(t); }
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
  public static void Click(int x, int y, int times) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(150);
    for (int i = 0; i < times; i++) {
      mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
      mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
      System.Threading.Thread.Sleep(70);
    }
  }
  public static void Tap(byte vk) {
    keybd_event(vk, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(30);
    keybd_event(vk, 0, 2, UIntPtr.Zero);
    System.Threading.Thread.Sleep(30);
  }
  public static void TypeAscii(string s) {
    foreach (char c in s) {
      if (c == ' ') { Tap(0x20); continue; }
      byte vk = (byte)char.ToUpperInvariant(c);
      bool shift = char.IsUpper(c);
      if (shift) keybd_event(0x10, 0, 0, UIntPtr.Zero);
      Tap(vk);
      if (shift) keybd_event(0x10, 0, 2, UIntPtr.Zero);
    }
  }
}
'@
[void][VmWin]::SetProcessDPIAware()

# ---------- 1. 找窗口 ----------
$hwnd = [VmWin]::Find($Match)
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "FAIL 没找到窗口（标题含 '$Match'）"; exit 2 }
$r = New-Object VmWin+RECT
[void][VmWin]::GetWindowRect($hwnd, [ref]$r)
$w = $r.R - $r.L
$h = $r.B - $r.T
[void][VmWin]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 600
Write-Output "OK   窗口 '$Match' 在 ($($r.L),$($r.T)) 尺寸 ${w}x${h}"

function Grab {
  $bmp = New-Object Drawing.Bitmap($w, $h)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object Drawing.Size($w, $h)))
  $g.Dispose()
  return $bmp
}

# ---------- 2. 需要的话先点一下（例如切标签页） ----------
if ($PreX -ge 0 -and $PreY -ge 0) {
  [VmWin]::Click(($r.L + $PreX), ($r.T + $PreY), 1)
  Start-Sleep -Milliseconds 600
  Write-Output "OK   已点击窗口内坐标 ($PreX,$PreY)"
}

# ---------- 3. 截图 + 找列表文本行 ----------
$bmp = Grab
if ($Out) { $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png) }
$bands = @()
$cur = @()
for ($y = $ListTop; $y -lt [Math]::Min($ListBottom, $bmp.Height); $y++) {
  $n = 0
  for ($x = $ListLeft; $x -lt [Math]::Min($ListRight, $bmp.Width); $x += 3) {
    $c = $bmp.GetPixel($x, $y)
    if (($c.R + $c.G + $c.B) / 3 -lt 120) { $n++ }
  }
  if ($n -gt 2) { $cur += $y } else { if ($cur.Count -gt 6) { $bands += , $cur }; $cur = @() }
}
if ($cur.Count -gt 6) { $bands += , $cur }
$bmp.Dispose()
Write-Output "OK   在列表区域检测到 $($bands.Count) 行文本"
if ($bands.Count -lt $Row) { Write-Output "FAIL 只找到 $($bands.Count) 行，取不到第 $Row 行"; exit 1 }
$b = $bands[$Row - 1]
$rowY = [int](($b[0] + $b[-1]) / 2)
$rowX = [int](($ListLeft + $ListRight) / 2)
Write-Output "OK   第 $Row 行文本 y=$($b[0])..$($b[-1])  点击窗口内 ($rowX,$rowY)"
if ($DryRun) { Write-Output 'SKIP -DryRun：不执行双击'; exit 0 }

# ---------- 4. 双击 ----------
[VmWin]::Click(($r.L + $rowX), ($r.T + $rowY), 2)

# ---------- 5. 等弹框 ----------
$dlg = [IntPtr]::Zero
$deadline = (Get-Date).AddMilliseconds(2500)
while ((Get-Date) -lt $deadline) {
  $dlg = [VmWin]::Find($Expect)
  if ($dlg -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 150
}
if ($dlg -eq [IntPtr]::Zero) {
  Write-Output "FAIL 双击后没有出现标题含 '$Expect' 的弹框"
  Write-Output ('     当前可见顶层窗口：' + ([VmWin]::Titles() -join ' | '))
  exit 1
}
Write-Output "PASS 双击弹出编辑框：'$([VmWin]::Title($dlg))'"

# ---------- 6. 可选：往弹框里输入并回车 ----------
if ($TypeInto) {
  $dr = New-Object VmWin+RECT
  [void][VmWin]::GetWindowRect($dlg, [ref]$dr)
  [void][VmWin]::SetForegroundWindow($dlg)
  Start-Sleep -Milliseconds 300
  [VmWin]::Click([int](($dr.L + $dr.R) / 2), ($dr.T + 60), 1)
  Start-Sleep -Milliseconds 250
  [VmWin]::TypeAscii($TypeInto)
  Start-Sleep -Milliseconds 200
  [VmWin]::Tap(0x0D)   # Enter
  Start-Sleep -Milliseconds 900
  $still = [VmWin]::Find($Expect)
  if ($still -eq [IntPtr]::Zero) { Write-Output "OK   已输入 '$TypeInto' 并回车，弹框已关闭" }
  else { Write-Output "WARN 输入后弹框仍然存在：'$([VmWin]::Title($still))'" }
}
exit 0
