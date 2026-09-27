Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$auto = [System.Windows.Automation.AutomationElement]
$root = $auto::RootElement

function Dump($el, $depth, $max) {
  if ($depth -gt $max) { return }
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $child = $walker.GetFirstChild($el)
  while ($child -ne $null) {
    $name = ''
    $aid  = ''
    $cls  = ''
    try { $name = $child.Current.Name } catch {}
    try { $aid  = $child.Current.AutomationId } catch {}
    try { $cls  = $child.Current.ClassName } catch {}
    if ($name -or $aid) {
      ('  ' * $depth) + "[$cls] name='$name' id='$aid'"
    }
    Dump $child ($depth + 1) $max
    $child = $walker.GetNextSibling($child)
  }
}

Write-Output '=== 查找任务栏 ==='
$taskbar = $null
$cond = New-Object System.Windows.Automation.PropertyCondition($auto::ClassNameProperty, 'Shell_TrayWnd')
$taskbar = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if ($taskbar) { "FOUND Shell_TrayWnd" } else { "no Shell_TrayWnd" }

Write-Output '=== 屏幕顶层窗口 ==='
$kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
foreach ($k in $kids) {
  $n=''; $c=''; $a=''
  try{$n=$k.Current.Name}catch{}; try{$c=$k.Current.ClassName}catch{}; try{$a=$k.Current.AutomationId}catch{}
  "  [$c] name='$n' id='$a'"
}

Write-Output '=== 任务栏元素（深度 4）==='
if ($taskbar) { Dump $taskbar 0 4 }
