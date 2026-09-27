Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;using System.Collections.Generic;
public class IP {
  [DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte sc,uint f,UIntPtr e);
  [DllImport("user32.dll")]public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")]public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")]public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
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
  public static string Windows(){
    List<string> res=new List<string>();
    EnumWindows((h,l)=>{ if(!IsWindowVisible(h))return true;
      var c=new StringBuilder(128); GetClassName(h,c,128);
      var s=new StringBuilder(256); GetWindowText(h,s,256);
      res.Add(c.ToString()+" | "+s.ToString()); return true;},IntPtr.Zero);
    return string.Join("\n",res); }
}
'@

function Wait([int]$ms){ $sw=[Diagnostics.Stopwatch]::StartNew(); while($sw.Elapsed.TotalMilliseconds -lt $ms){ [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } }

"== CurrentInputLanguage =="
$cur = [System.Windows.Forms.InputLanguage]::CurrentInputLanguage
"handle=0x$($cur.Handle.ToString('X8')) culture=$($cur.Culture.Name)"
"== InstalledInputLanguages =="
$i = 0
foreach ($il in [System.Windows.Forms.InputLanguage]::InstalledInputLanguages) {
  "[$i] handle=0x$($il.Handle.ToString('X8')) culture=$($il.Culture.Name)"
  $i++
}

$f = New-Object System.Windows.Forms.Form
$f.Text = 'IME-PROBE'
$f.StartPosition='Manual'; $f.Location=New-Object Drawing.Point(60,120); $f.Size=New-Object Drawing.Size(600,240)
$t = New-Object System.Windows.Forms.TextBox; $t.Dock='Fill'; $t.Font=New-Object Drawing.Font('Consolas',14)
[void]$f.Controls.Add($t); $f.Add_Shown({$t.Focus()})
$f.Show(); Wait 400
$ok=[IP]::Focus($f.Handle); "FOCUS=$ok"

# tap 'n' to start composition, then dump visible windows to spot the candidate panel
[IP]::keybd_event(0x4E,[byte][uint32]0,0,[UIntPtr]::Zero); Wait 90; [IP]::keybd_event(0x4E,[byte]0,2,[UIntPtr]::Zero); Wait 900
"== visible windows during composition =="
[IP]::Windows()
"text=<$($t.Text)>"
[IP]::keybd_event(0x1B,[byte]0,0,[UIntPtr]::Zero); Wait 60; [IP]::keybd_event(0x1B,[byte]0,2,[UIntPtr]::Zero); Wait 300
$f.Close()
