Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;using System.Collections.Generic;
public class IP2 {
  [DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte sc,uint f,UIntPtr e);
  [DllImport("user32.dll")]public static extern uint MapVirtualKey(uint c,uint t);
  [DllImport("user32.dll")]public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")]public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")]public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")]public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("kernel32.dll")]public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]public static extern bool AttachThreadInput(uint a,uint b,bool f);
  public delegate bool EnumProc(IntPtr h,IntPtr l);
  public static bool Focus(IntPtr hwnd){
    ShowWindow(hwnd,9); System.Threading.Thread.Sleep(150);
    uint zpid=0; uint tid1=GetWindowThreadProcessId(GetForegroundWindow(),out zpid); uint tid2=GetCurrentThreadId();
    AttachThreadInput(tid1,tid2,true); BringWindowToTop(hwnd); SetForegroundWindow(hwnd); AttachThreadInput(tid1,tid2,false);
    System.Threading.Thread.Sleep(200); return GetForegroundWindow()==hwnd; }
  public static void Tap(byte vk){
    byte sc=(byte)MapVirtualKey(vk,0);
    keybd_event(vk,sc,0,UIntPtr.Zero); System.Threading.Thread.Sleep(60);
    keybd_event(vk,sc,2,UIntPtr.Zero); System.Threading.Thread.Sleep(60); }
  public static string FgTitle(){
    var sb=new StringBuilder(300); GetWindowText(GetForegroundWindow(),sb,300); return sb.ToString(); }
  public static string PanelInfo(){
    string res="none";
    EnumWindows((h,l)=>{ if(!IsWindowVisible(h))return true;
      var c=new StringBuilder(128); GetClassName(h,c,128);
      string cs=c.ToString();
      if(cs.StartsWith("ATL:")||cs.IndexOf("IME")>=0||cs.IndexOf("Weasel")>=0){
        uint pid=0; GetWindowThreadProcessId(h,out pid);
        var r=new RECT(); GetWindowRect(h,out r);
        res=cs+" pid="+pid+" rect="+r.L+","+r.T+","+(r.Rr-r.L)+"x"+(r.B-r.T); }
      return true;},IntPtr.Zero);
    return res; }
  [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out RECT r);
  public struct RECT{public int L,T,Rr,B;}
}
'@

function Wait([int]$ms){ $sw=[Diagnostics.Stopwatch]::StartNew(); while($sw.Elapsed.TotalMilliseconds -lt $ms){ [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } }

$f = New-Object System.Windows.Forms.Form
$f.Text = 'IME-PROBE2'
$f.StartPosition='Manual'; $f.Location=New-Object Drawing.Point(60,300); $f.Size=New-Object Drawing.Size(700,300)
$t = New-Object System.Windows.Forms.TextBox; $t.Dock='Fill'; $t.Multiline=$true; $t.Font=New-Object Drawing.Font('Consolas',14)
[void]$f.Controls.Add($t); $f.Add_Shown({$t.Focus()})
$f.Show(); Wait 400
"FOCUS=$([IP2]::Focus($f.Handle))"

function Step([string]$label){
  Wait 350
  $panel = [IP2]::PanelInfo()
  $proc = ''
  if ($panel -match 'pid=(\d+)') { try { $proc = (Get-Process -Id ([int]$Matches[1])).Name } catch {} }
  $fg = [IP2]::FgTitle()
  "  [$label] fg=<$fg> panel={$panel} owner=$proc text=<$($t.Text)>"
}

"== typing n i h a o slowly =="
foreach ($ch in [char[]]'nihao') {
  $vk = [int][char]::ToLower($ch) - 0x20
  [IP2]::Tap([byte]$vk)
  Step ("after " + $ch)
}
"== screenshot full screen =="
$bmp = New-Object Drawing.Bitmap ([int]1400), ([int]700)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0,0,0,0,(New-Object Drawing.Size(1400,700)))
$bmp.Save((Join-Path $env:TEMP 'probe-composition.png'),[Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"== press space =="
[IP2]::Tap(0x20); Step "after space"
$f.Close()
