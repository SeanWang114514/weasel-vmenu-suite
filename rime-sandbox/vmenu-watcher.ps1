param(
  [string]$RimeDir = '',
  [int]$IntervalMs = 500
)
# Resolve the Rime user dir when not passed explicitly:
# env override -> registry RimeUserDir -> %APPDATA%\Rime -> legacy dev dir.
if (-not $RimeDir) { $RimeDir = $env:RIME_DIR }
if (-not $RimeDir) {
  try {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir -ErrorAction Stop
    if ($reg.RimeUserDir) { $RimeDir = $reg.RimeUserDir }
  } catch {}
}
if (-not $RimeDir) { $RimeDir = Join-Path $env:APPDATA 'Rime' }
if (-not (Test-Path -LiteralPath $RimeDir) -and (Test-Path -LiteralPath 'D:\rime-sandbox')) { $RimeDir = 'D:\rime-sandbox' }
# Supervisor for the RESIDENT settings window.
#
# Why this design:
#   * The IME must NEVER spawn a process. Doing that from the Rime input thread
#     (io.popen / os.execute) is exactly what used to freeze the input method.
#     So the Lua side only writes <RimeDir>\open-settings.flag.
#   * vmenu-settings-gui.ps1 now stays resident: it builds its window hidden,
#     then polls that flag file every 60 ms and shows itself instantly.
#     Pressing  v  then  1  therefore costs ~0.1 s instead of the 2-4 s it takes
#     to start PowerShell and parse the 690-line script again.
#   * This watcher only keeps ONE resident GUI alive and restarts it if it died,
#     so  v -> 1  always works.
#
# ASCII-only source on purpose: Windows PowerShell 5.1 parses BOM-less UTF-8
# scripts as ANSI, which breaks quoting when non-ASCII characters are present.

$ErrorActionPreference = 'SilentlyContinue'

# Single instance: starting a second supervisor is harmless but pointless, so
# every extra one exits immediately (see 打开设置.bat / clipboard-sync.bat).
$mutex = New-Object System.Threading.Mutex($false, 'RimeVMenuWatcher')
$isFirst = $false
try { $isFirst = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $isFirst = $true }
catch { $isFirst = $false }
if (-not $isFirst) { exit 0 }

$flag = Join-Path $RimeDir 'open-settings.flag'
# Assembled at runtime so that a command line merely mentioning the GUI script
# (including this process) can never match the pattern we search for.
$guiName = 'vmenu-' + 'settings-gui.ps1'
$gui = Join-Path $PSScriptRoot $guiName

if (-not (Test-Path -LiteralPath $gui)) {
  Write-Host "vmenu-watcher: GUI script not found: $gui"
  exit 1
}

while ($true) {
  # Liveness probe: the resident GUI holds the 'RimeVMenuSettingsGui' mutex for its
  # whole lifetime, so OpenExisting answers in ~0.1ms. The old probe was
  # Get-CimInstance Win32_Process (measured: 176ms per call!) every 500ms - that
  # burned a large slice of a core continuously and stole CPU from the very window
  # it supervises.
  $alive = $false
  try {
    $m = [System.Threading.Mutex]::OpenExisting('RimeVMenuSettingsGui')
    $m.Dispose()
    $alive = $true
  } catch { $alive = $false }

  if (-not $alive) {
    # Prefer the console-less launcher (VMenu.exe): it creates the child process
    # with CreateNoWindow=true, so nothing black ever flashes on screen.
    $exe = Join-Path $PSScriptRoot 'VMenu.exe'
    if (Test-Path -LiteralPath $exe) {
      Start-Process -FilePath $exe -ArgumentList 'gui', '--rime', $RimeDir -WindowStyle Hidden
    } else {
      $pArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                 '-File', $gui, '-RimeDir', $RimeDir)
      # A pending flag means the window was requested while nothing was alive:
      # start the new instance with the window already shown.
      if (Test-Path -LiteralPath $flag) { $pArgs += '-ShowNow' }
      Start-Process -FilePath 'powershell.exe' -ArgumentList $pArgs -WindowStyle Hidden
    }
    Start-Sleep -Seconds 3
  }

  Start-Sleep -Milliseconds $IntervalMs
}
