param([int]$Gap = 250)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public class IP3 {
  [DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte sc,uint f,UIntPtr e);
  [DllImport("user32.dll")]public static extern uint MapVirtualKey(uint c,uint t);
  [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")]public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("kernel32.dll")]public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]public static extern bool AttachThreadInput(uint a,uint b,bool f);
  public static bool Focus(IntPtr hwnd){
    ShowWindow(hwnd,9); System.Threading.Thread.Sleep(150);
    uint zpid=0; uint tid1=GetWindowThreadProcessId(GetForegroundWindow(),out zpid); uint tid2=GetCurrentThreadId();
    AttachThreadInput(tid1,tid2,true); BringWindowToTop(hwnd); SetForegroundWindow(hwnd); AttachThreadInput(tid1,tid2,false);
    System.Threading.Thread.Sleep(200); return GetForegroundWindow()==hwnd; }
  public static void Tap(byte vk, bool shift){
    if(shift){ keybd_event(0x10,0x2A,0,UIntPtr.Zero); System.Threading.Thread.Sleep(40); }
    byte sc=(byte)MapVirtualKey(vk,0);
    keybd_event(vk,sc,0,UIntPtr.Zero); System.Threading.Thread.Sleep(70);
    keybd_event(vk,sc,2,UIntPtr.Zero); System.Threading.Thread.Sleep(70);
    if(shift){ keybd_event(0x10,0x2A,2,UIntPtr.Zero); System.Threading.Thread.Sleep(40); } }
}
'@

function Wait([int]$ms){ $sw=[Diagnostics.Stopwatch]::StartNew(); while($sw.Elapsed.TotalMilliseconds -lt $ms){ [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } }
function Shot([string]$name){
  $p = Join-Path $env:TEMP ("punct-" + $name + ".png")
  $bmp = New-Object Drawing.Bitmap ([int]1500), ([int]800)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0,0,0,0,(New-Object Drawing.Size(1500,800)))
  $bmp.Save($p,[Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
  "  shot -> $p"
}
function VK([string]$c){
  $lo = [string][char]::ToLower($c[0])
  if ($c.Length -eq 1 -and $lo -ge 'a' -and $lo -le 'z') { return @(([int][char]$lo - 0x20), ($c -cne $lo)) }
  switch ($c) {
    '.' { return @(0xBE, $false) }
    ':' { return @(0xBA, $true) }
    '\' { return @(0xDC, $false) }
    '/' { return @(0xBF, $false) }
    ' ' { return @(0x20, $false) }
    'esc' { return @(0x1B, $false) }
    default { throw "unmapped $c" }
  }
}
function Tap([string]$c){ $e = (VK $c); [IP3]::Tap([byte]$e[0], [bool]$e[1]) }

$f = New-Object System.Windows.Forms.Form
$f.Text = 'IME-PROBE3'
$f.StartPosition='Manual'; $f.Location=New-Object Drawing.Point(60,80); $f.Size=New-Object Drawing.Size(760,360)
$t = New-Object System.Windows.Forms.TextBox; $t.Dock='Fill'; $t.Multiline=$true; $t.Font=New-Object Drawing.Font('Consolas',16)
[void]$f.Controls.Add($t); $f.Add_Shown({$t.Focus()})
$f.Show(); Wait 400
"FOCUS=$([IP3]::Focus($f.Handle))"

function Stage([string]$name, [string[]]$keys) {
  foreach ($k in $keys) { Tap $k; Wait $Gap }
  Wait 500
  "stage=$name text=<$($t.Text)>"
  Shot $name
}

# start from clean state
Tap 'esc'; Wait 300
$t.Clear()

Stage '1-www'      @('w','w','w')
Stage '2-wwwdot'   @('.')
Stage '3-baidu'    @('b','a','i','d','u')
Stage '4-baidudot' @('.')
Stage '5-com'      @('c','o','m')
Stage '6-space'    @(' ')
$f.Close()
