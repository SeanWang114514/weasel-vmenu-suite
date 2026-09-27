param([string]$Target = 'notepad')
# Dump the foreground app's document text via UI Automation (TextPattern),
# so we can see the exact composition string the IME put in the document.
# ASCII-only source on purpose: PS 5.1 parses BOM-less UTF-8 as ANSI.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement
$pid2 = (Get-Process $Target -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).Id
$cond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pid2)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) { 'NO_WINDOW'; exit 2 }

$found = $false
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$stack = New-Object System.Collections.Stack
$stack.Push($win)
$bestText = $null
$bestName = ''
while ($stack.Count -gt 0) {
  $n = $stack.Pop()
  $tp = $null
  try {
    if ($n.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$tp) -and $tp) {
      $t = $tp.DocumentRange.GetText(4000)
      if ($t.Length -gt $bestText.Length) { $bestText = $t; $bestName = $n.Current.Name + '|' + $n.Current.ControlType.ProgrammaticName }
      $found = $true
    }
  } catch {}
  $child = $walker.GetFirstChild($n)
  while ($child) { $stack.Push($child); $child = $walker.GetNextSibling($child) }
}
if (-not $found -or $null -eq $bestText) { 'NO_TEXTPATTERN' } else {
  $text = $bestText
  'NAME=' + $bestName
  'REGION=' + $text.Replace("`r", '<CR>').Replace("`n", '<LF>')
  $cps = New-Object System.Text.StringBuilder
  foreach ($c in $text.ToCharArray()) { [void]$cps.AppendFormat('{0:X4} ', [int]$c) }
  'CODEPOINTS=' + $cps.ToString()
}
