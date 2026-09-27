param(
  [ValidateSet('dump','deploy')]
  [string]$Action = 'dump'
)
# Right-click the IME input indicator and (optionally) click the "Deploy" item.
# ASCII-only source on purpose: Windows PowerShell 5.1 parses BOM-less UTF-8
# scripts as ANSI, which corrupts quoting when non-ASCII comments are present.

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Mz2 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
  public static void RightClick(int x,int y){
    SetCursorPos(x,y);
    System.Threading.Thread.Sleep(150);
    mouse_event(0x0008,0,0,0,UIntPtr.Zero);
    System.Threading.Thread.Sleep(60);
    mouse_event(0x0010,0,0,0,UIntPtr.Zero);
  }
  public static void LeftClick(int x,int y){
    SetCursorPos(x,y);
    System.Threading.Thread.Sleep(150);
    mouse_event(0x0002,0,0,0,UIntPtr.Zero);
    System.Threading.Thread.Sleep(60);
    mouse_event(0x0004,0,0,0,UIntPtr.Zero);
  }
}
"@

$auto = [System.Windows.Automation.AutomationElement]
$root = $auto::RootElement
$NL = [char]10
$IND_PREFIX = [string]::Join('', [char]0x6258, [char]0x76D8, [char]0x8F93, [char]0x5165, [char]0x6307, [char]0x793A, [char]0x5668)
$DEPLOY_CN = [string]::Join('', [char]0x91CD, [char]0x65B0, [char]0x90E8, [char]0x7F72)

function Get-Indicator {
  $cond = New-Object System.Windows.Automation.PropertyCondition($auto::AutomationIdProperty, 'SystemTrayIcon')
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
  foreach ($e in $all) {
    try { if ($e.Current.Name.StartsWith($IND_PREFIX)) { return $e } } catch {}
  }
  return $null
}

$ind = Get-Indicator
if (-not $ind) { 'INDICATOR_NOT_FOUND'; exit 1 }
$r = $ind.Current.BoundingRectangle
$cx = [int]($r.X + $r.Width/2); $cy = [int]($r.Y + $r.Height/2)
"INDICATOR_AT=$cx,$cy"
[Mz2]::RightClick($cx,$cy)
Start-Sleep -Milliseconds 1200

# Collect every menu item currently on screen, with its bounding box.
$items = @()
$kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
foreach ($k in $kids) {
  $cn = ''; try { $cn = $k.Current.ClassName } catch {}
  $desc = $k.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($d in $desc) {
    $ct = ''; $nm = ''
    try { $ct = $d.Current.ControlType.ProgrammaticName } catch {}
    try { $nm = $d.Current.Name } catch {}
    if ($nm -and $nm.Trim().Length -gt 0) {
      $items += [pscustomobject]@{ Name = ($nm -split $NL)[0]; Type = $ct; Rect = $d.Current.BoundingRectangle; Elem = $d }
    }
  }
}

"--- MENU ITEMS ($($items.Count)) ---"
foreach ($it in $items) {
  $rr = $it.Rect
  "  [$($it.Type)] '$($it.Name)'  @ $([int]$rr.X),$([int]$rr.Y),$([int]$rr.Width)x$([int]$rr.Height)"
}

if ($Action -eq 'deploy') {
  $hit = $null
  foreach ($it in $items) {
    if ($it.Type -like '*MenuItem*' -and ($it.Name -like "*Deploy*" -or $it.Name -like "*$DEPLOY_CN*")) { $hit = $it; break }
  }
  if (-not $hit) { 'DEPLOY_ITEM_NOT_FOUND'; exit 2 }
  $rr = $hit.Rect
  $hx = [int]($rr.X + $rr.Width/2); $hy = [int]($rr.Y + $rr.Height/2)
  "CLICK_DEPLOY '$($hit.Name)' at $hx,$hy"
  [Mz2]::LeftClick($hx,$hy)
}
