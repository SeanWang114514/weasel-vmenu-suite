$ErrorActionPreference = 'SilentlyContinue'
# Stop every other vmenu-watcher.ps1 process, plus the resident settings window
# it supervises (the window is a long-lived hidden process, so it has to be
# restarted whenever the watcher is restarted).
#
# Both patterns are assembled at runtime and $PID is excluded: a command line
# that merely MENTIONS a script name (including this one) must never match itself.
$me = $PID
$patWatcher = 'vmenu-' + 'watcher.ps1'
$patGui = 'vmenu-' + 'settings-gui.ps1'

$nw = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and $_.CommandLine.IndexOf($patWatcher) -ge 0 } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $nw++ }

$ng = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and $_.CommandLine.IndexOf($patGui) -ge 0 } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $ng++ }

"stopped $nw watcher instance(s), $ng settings window instance(s)"
