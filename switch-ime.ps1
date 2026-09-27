param(
  [ValidateSet('report','open','list','pick')]
  [string]$Action = 'report',
  [string]$Match = ''
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Mz {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
  public static void Click(int x,int y){
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
# Tray input indicator label prefix: "Tray input indicator"
$IND_PREFIX = [string]::Join('', [char]0x6258, [char]0x76D8, [char]0x8F93, [char]0x5165, [char]0x6307, [char]0x793A, [char]0x5668)

function Get-Indicator {
  $cond = New-Object System.Windows.Automation.PropertyCondition($auto::AutomationIdProperty, 'SystemTrayIcon')
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
  foreach ($e in $all) {
    try {
      if ($e.Current.Name.StartsWith($IND_PREFIX)) { return $e }
    } catch {}
  }
  return $null
}

function Show-TopWindows {
  $kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($k in $kids) {
    $n=''; $c=''
    try{$n=$k.Current.Name}catch{}; try{$c=$k.Current.ClassName}catch{}
    "  [$c] name='" + ($n -split $NL) -join ' | ' + "'"
  }
}

switch ($Action) {
  'report' {
    $ind = Get-Indicator
    if ($ind) {
      $nm = ($ind.Current.Name -split $NL) -join ' | '
      "INDICATOR_NAME=$nm"
      $r = $ind.Current.BoundingRectangle
      "RECT=$([int]$r.X),$([int]$r.Y),$([int]$r.Width),$([int]$r.Height)"
    } else { 'INDICATOR_NOT_FOUND' }
  }
  'open' {
    $ind = Get-Indicator
    if (-not $ind) { 'INDICATOR_NOT_FOUND'; exit 1 }
    $r = $ind.Current.BoundingRectangle
    $cx = [int]($r.X + $r.Width/2); $cy = [int]($r.Y + $r.Height/2)
    "CLICK_AT=$cx,$cy"
    [Mz]::Click($cx,$cy)
    Start-Sleep -Milliseconds 1500
    Show-TopWindows
  }
  'list' {
    Show-TopWindows
  }
  'pick' {
    $kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $hit = $null
    foreach ($k in $kids) {
      try { if ($k.Current.Name -like "*$Match*") { $hit = $k; break } } catch {}
    }
    if (-not $hit) {
      foreach ($k in $kids) {
        try {
          $c2 = New-Object System.Windows.Automation.PropertyCondition($auto::NameProperty, $Match)
          $d = $k.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c2)
          if ($d) { $hit = $d; break }
        } catch {}
      }
    }
    if ($hit) {
      $r = $hit.Current.BoundingRectangle
      $cx=[int]($r.X+$r.Width/2); $cy=[int]($r.Y+$r.Height/2)
      "PICK name='" + $hit.Current.Name + "' at $cx,$cy"
      [Mz]::Click($cx,$cy)
      Start-Sleep -Milliseconds 1000
      $ind2 = Get-Indicator
      $nm2 = ($ind2.Current.Name -split $NL) -join ' | '
      "AFTER=$nm2"
    } else { "PICK_NOT_FOUND" }
  }
}
