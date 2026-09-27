param(
  [string]$Case = 'all',
  [switch]$Trace,
  [switch]$SkipProbe,
  [switch]$SkipReset,
  [switch]$NoGuard,
  [switch]$NoPump
)
# punct-test.ps1 -- baseline & regression test for context punctuation
# (URL "." and Windows path "\" behaviour). Own pad window, key injection,
# reads back the TextBox text directly. ASCII-only source on purpose:
# a BOM-less .ps1 with non-ASCII parses as ANSI on Windows PowerShell 5.1.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public class PT {
  [DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte sc,uint f,UIntPtr e);
  [DllImport("user32.dll")]public static extern uint MapVirtualKey(uint c,uint t);
  [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")]public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")]public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out RECT r);
  public struct RECT{public int L,T,Rr,B;}
  public delegate bool EnumProc(IntPtr h,IntPtr l);
  public static string Comp(){
    string res="none";
    EnumWindows((h,l)=>{ if(!IsWindowVisible(h))return true;
      var c=new StringBuilder(128); GetClassName(h,c,128);
      string cs=c.ToString();
      if(cs.IndexOf("MSCTFIME")>=0||cs.StartsWith("ATL:")){
        RECT r; GetWindowRect(h,out r);
        res=cs+" "+(r.Rr-r.L)+"x"+(r.B-r.T)+"@"+r.L+","+r.T; }
      return true;},IntPtr.Zero);
    return res; }
  public static string FgTitle(){ var sb=new StringBuilder(300); GetWindowText(GetForegroundWindow(),sb,300); return sb.ToString(); }
  [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")]public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("kernel32.dll")]public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]public static extern bool AttachThreadInput(uint a,uint b,bool f);
  public static void Down(byte vk){byte sc=(byte)MapVirtualKey(vk,0);keybd_event(vk,sc,0,UIntPtr.Zero);}
  public static void Up(byte vk){byte sc=(byte)MapVirtualKey(vk,0);keybd_event(vk,sc,2,UIntPtr.Zero);}
  public static bool Focus(IntPtr hwnd){
    ShowWindow(hwnd,9); System.Threading.Thread.Sleep(150);
    uint zpid=0; uint tid1=GetWindowThreadProcessId(GetForegroundWindow(),out zpid); uint tid2=GetCurrentThreadId();
    AttachThreadInput(tid1,tid2,true); BringWindowToTop(hwnd); SetForegroundWindow(hwnd); AttachThreadInput(tid1,tid2,false);
    System.Threading.Thread.Sleep(200);
    if(GetForegroundWindow()!=hwnd){ keybd_event(0x12,0,0,UIntPtr.Zero); System.Threading.Thread.Sleep(40); keybd_event(0x12,0,2,UIntPtr.Zero); System.Threading.Thread.Sleep(80); SetForegroundWindow(hwnd); System.Threading.Thread.Sleep(200);}
    return GetForegroundWindow()==hwnd; }
}
'@

function Wait([int]$ms) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalMilliseconds -lt $ms) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 15
  }
}

# char -> @(vk, shift). NOTE: must be a case-SENSITIVE dictionary: PS @{} is
# case-insensitive and the uppercase loop would overwrite the lowercase keys
# (that bug made every letter send with Shift held -> keys appeared dropped).
$map = New-Object 'System.Collections.Generic.Dictionary[string,object[]]'
foreach ($c in [char[]]'abcdefghijklmnopqrstuvwxyz') { $map[[string]$c] = @(([int]$c - 0x20), $false) }
foreach ($c in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') { $map[[string]$c] = @(([int][char]::ToLower($c) - 0x20), $true) }
foreach ($i in 0..9) { $map["$i"] = @((0x30 + $i), $false) }
$map['.'] = @(0xBE, $false); $map[','] = @(0xBC, $false)
$map['\'] = @(0xDC, $false); $map['/'] = @(0xBF, $false)
$map[';'] = @(0xBA, $false); $map[':'] = @(0xBA, $true)
$map['-'] = @(0xBD, $false); $map['_'] = @(0xBD, $true)
$map['='] = @(0xBB, $false); $map['+'] = @(0xBB, $true)
$map['?'] = @(0xBF, $true);  $map['!'] = @(0x31, $true)
$map['@'] = @(0x32, $true);  $map['#'] = @(0x33, $true)
$map['%'] = @(0x35, $true);  $map['&'] = @(0x37, $true)
$map["'"] = @(0xDE, $false); $map['"'] = @(0xDE, $true)
$map['`'] = @(0xC0, $false); $map['~'] = @(0xC0, $true)
$map['['] = @(0xDB, $false); $map[']'] = @(0xDD, $false)
$map['('] = @(0x39, $true);  $map[')'] = @(0x30, $true)
$map[' '] = @(0x20, $false)
$named = @{ '<space>'=0x20; '<esc>'=0x1B; '<back>'=0x08; '<enter>'=0x0D; '<shift>'=0x10; '<tab>'=0x09 }

function EnsureFocus {
  if ($NoGuard) { return }
  if ([PT]::GetForegroundWindow() -ne $f.Handle) {
    [void][PT]::Focus($f.Handle); Wait 150
  }
}

function SendChar([string]$ch) {
  EnsureFocus
  $script:fgseen[( [PT]::FgTitle() )] = 1
  $e = $map[$ch]
  if ($null -eq $e) { throw "no key map for: [$ch]" }
  if ($e[1]) {
    [PT]::Down(0x10); Start-Sleep -Milliseconds 60
    # pump so the IME processes the shift-down BEFORE the next key arrives;
    # otherwise both events dispatch in one burst and vmenu's misinput_protect
    # (CPU-time delta < interval) swallows the shifted key.
    Wait 60; Start-Sleep -Milliseconds 60
  }
  # No message pumping while a key is half-pressed (reentrancy disturbs the
  # IME -> observed key drops); pump only after key-up, before the next key.
  [PT]::Down([byte]$e[0]); Start-Sleep -Milliseconds 80; [PT]::Up([byte]$e[0]); Start-Sleep -Milliseconds 80
  if ($e[1]) {
    [PT]::Up(0x10); Start-Sleep -Milliseconds 90
    # safety: force-release shift again (a lost shift-up poisons all later keys)
    [PT]::Up(0x10); Start-Sleep -Milliseconds 40
  }
  if ($NoPump) { Start-Sleep -Milliseconds 60 } else { Wait 60 }
  if ($Trace) {
    $script:shotn++
    "    trace ch=[$ch] vk=$($e[0]) shift=$($e[1]) text=<$($t.Text)> comp=<" + ([PT]::Comp()) + ">"
  }
}

function SendToken([string]$tok) {
  EnsureFocus
  if ($named.ContainsKey($tok)) {
    [PT]::Down([byte]$named[$tok]); Start-Sleep -Milliseconds 70; [PT]::Up([byte]$named[$tok]); Start-Sleep -Milliseconds 150
  } else {
    foreach ($c in $tok.ToCharArray()) { SendChar([string]$c) }
    Wait 200
  }
  if ($Trace) {
    $fg = [PT]::FgTitle()
    "    trace tok=[$tok] fg=<$fg> text=<$($t.Text)>"
  }
}

# ---- pad window ----
$script:shotn = 0
$script:fgseen = @{}
$f = New-Object System.Windows.Forms.Form
$f.Text = 'DSH-IME-PUNCT-TEST'
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point(60, 80)
$f.Size = New-Object System.Drawing.Size(960, 420)
$t = New-Object System.Windows.Forms.TextBox
$t.Multiline = $true; $t.Dock = 'Fill'; $t.AcceptsTab = $true
$t.Font = New-Object System.Drawing.Font('Consolas', 14)
[void]$f.Controls.Add($t)
$f.Add_Shown({ $t.Focus() })
$f.Show()
Wait 400
$ok = [PT]::Focus($f.Handle)
"FOCUS=$ok"
"PAD_BOUNDS=$($f.Bounds)  SCREEN=$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds)  WORK=$([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea)"
if (-not $ok) { 'ABORT: cannot focus pad'; exit 2 }

function TapName([string]$n) { SendToken $n }
function Reset-State {
  SendToken '<esc>'; Wait 120
  $t.Clear(); Wait 80
}

# ---- Chinese-mode probe ----
function Probe-Chinese {
  $t.Clear(); Wait 80
  SendChar 'n'; Wait 450
  $sawAscii = ($t.Text -match 'n')
  Reset-State
  return (-not $sawAscii)
}
$cn = $true
if (-not $SkipProbe) {
  $cn = Probe-Chinese
  if (-not $cn) {
    'MODE was ASCII, pressing Shift_L to switch...'
    TapName '<shift>'; Wait 400
    $cn = Probe-Chinese
  }
}
"CHINESE_MODE=$cn"
if (-not $cn) { 'ABORT: cannot enter Chinese mode'; exit 3 }

# ---- cases ----
$cases = @(
  @{ n = 'A www.baidu.com+space'; k = @('www.baidu.com', '<space>') },
  @{ n = 'B google.com+space';    k = @('google.com', '<space>') },
  @{ n = 'C baidu.com+space';     k = @('baidu.com', '<space>') },
  @{ n = 'D nihao.+space';        k = @('nihao.', '<space>') },
  @{ n = 'E D:\ruanjian+space';   k = @('D', ':', '\', 'ruanjian', '<space>') },
  @{ n = 'F file.txt+space';      k = @('file.txt', '<space>') },
  @{ n = 'G D:+space';            k = @('D', ':', '<space>') },
  @{ n = 'H lower d:\ruanjian';   k = @('d', ':', '\', 'ruanjian', '<space>') },
  @{ n = 'I www+space';           k = @('www', '<space>') },
  @{ n = 'J baidu+space';         k = @('baidu', '<space>') },
  @{ n = 'K nihao+space';         k = @('nihao', '<space>') },
  @{ n = 'L www.baidu+space';     k = @('www.baidu', '<space>') },
  @{ n = 'M baidudot+space';      k = @('baidu', '.', '<space>') },
  @{ n = 'N long path cn';        k = @('D', ':', '\', 'ruanjian', '\', 'xiangmu', '<space>') },
  @{ n = 'O long path en';        k = @('D', ':', '\', 'project', '\', 'src', '\', 'main.py', '<space>') },
  @{ n = 'P path cn + ext';       k = @('D', ':', '\', 'ruanjian', '\', 'wendang.txt', '<space>') },
  @{ n = 'Q users path';          k = @('C', ':', '\', 'Users', '\', 'Administrator', '<space>') },
  @{ n = 'R path then cn comma';  k = @('D', ':', '\', 'ruanjian', ',', 'nihao', '<space>') }
)
$selected = if ($Case -eq 'all') { $cases } else { $cases | Where-Object { $_.n -like "$Case*" } }

"===== BASELINE ====="
foreach ($c in $selected) {
  if (-not $SkipReset) { Reset-State }
  [void][PT]::Focus($f.Handle); Wait 150
  foreach ($k in $c.k) { SendToken $k }
  Wait 900
  $txt = $t.Text
  "[$($c.n)] => <$txt>"
  "    fg-titles-during-keys: " + (($script:fgseen.Keys | ForEach-Object { "<$_>" }) -join ' ')
}
Reset-State
"===== DONE ====="
