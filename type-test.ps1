# type-test.ps1 — ASCII only, STA timing test for txtWord input handling
. 'D:\VibeCoding\输入法\dict-manager.ps1'
$w = New-ManagerWindow
$tw = $w.FindName('txtWord')
$tp = $w.FindName('txtPinyin')
$tip = $w.FindName('lblAddTip')
$sw = [Diagnostics.Stopwatch]::StartNew()
$tw.Text = 'd'
$sw.Stop()
Write-Host ("set_text_ms=" + $sw.Elapsed.TotalMilliseconds)
$frame = New-Object System.Windows.Threading.DispatcherFrame
$dt = New-Object System.Windows.Threading.DispatcherTimer
$dt.Interval = [TimeSpan]::FromMilliseconds(400)
$dt.Add_Tick({ $dt.Stop(); $frame.Continue = $false })
$dt.Start()
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
Write-Host ("pinyin=[" + $tp.Text + "]")
Write-Host ("tip=[" + $tip.Text + "]")
Write-Host ("rows=" + $w.FindName('grid').Items.Count)
Write-Host DONE
