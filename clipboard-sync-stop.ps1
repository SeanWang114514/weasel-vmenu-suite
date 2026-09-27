param()
# Stop every other clipboard-sync.ps1 instance. Lives in its own file so the
# CommandLine match below cannot accidentally match this process:
# its own command line holds "clipboard-sync-stop.ps1", which does NOT contain
# the substring "clipboard-sync.ps1" that we search for.
#
# ASCII-only source on purpose (Windows PowerShell 5.1 + BOM-less UTF-8 caveat).

$me = $PID
$killed = 0
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -eq 'powershell.exe' -and
    $_.ProcessId -ne $me -and
    $_.CommandLine -and
    $_.CommandLine -like '*-File*clipboard-sync.ps1*'
  } |
  ForEach-Object {
    try {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
      $killed++
      "stopped clipboard-sync pid=$($_.ProcessId)"
    } catch {
      "failed to stop pid=$($_.ProcessId): $($_.Exception.Message)"
    }
  }
"stopped $killed instance(s)"
