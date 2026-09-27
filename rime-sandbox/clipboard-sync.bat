@echo off
chcp 65001 >nul
rem Start (or restart) the background helpers the v-menu feature needs.
rem
rem   1) clipboard-sync.ps1  - mirrors the Windows clipboard into
rem      <RimeDir>\clipboard-cache.txt (one entry per line, newest first,
rem      de-duplicated, capped). Runs outside the IME on purpose: reading the
rem      clipboard from inside the Rime input thread used to freeze typing.
rem   2) the supervisor       - keeps ONE resident settings window alive.
rem      vmenu-settings-gui.ps1 builds its window hidden and watches
rem      <RimeDir>\open-settings.flag, which the IME writes when you press  v
rem      then  1 ; the window then appears in about 0.1 s. The IME never spawns
rem      a process itself (spawning from the Rime input thread used to freeze
rem      typing).
rem
rem Everything is started through VMenu.exe (a GUI-subsystem exe): it spawns its
rem children with CreateNoWindow=true, so no console window ever flashes - the
rem old  start /min powershell.exe  lines always flashed one.
rem Kept ASCII-only on purpose: cmd.exe decodes a .bat with the active code page
rem and desyncs on multi-byte characters split across read buffers.
rem Resolve the Rime user dir: env override -> registry -> %APPDATA%\Rime.
if not defined RIME_DIR for /f "tokens=2*" %%a in ('reg query "HKCU\SOFTWARE\Rime\Weasel" /v RimeUserDir 2^>nul') do set "RIME_DIR=%%b"
if not defined RIME_DIR set "RIME_DIR=%APPDATA%\Rime"

if exist "%~dp0VMenu.exe" (
  rem stop whatever is already running (settings window + supervisor + sync)
  "%~dp0VMenu.exe" stop
  rem and start it all again, hidden, then ask for the settings window
  "%~dp0VMenu.exe" start
  "%~dp0VMenu.exe" open
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clipboard-sync-stop.ps1"
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vmenu-watcher-stop.ps1"
  start "Rime Clipboard Sync" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0clipboard-sync.ps1" -RimeDir "%RIME_DIR%" -Max 50 -IntervalMs 1000 >nul 2>&1
  start "Rime V-Menu Watcher" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0vmenu-watcher.ps1" -RimeDir "%RIME_DIR%" >nul 2>&1
  >"%RIME_DIR%\open-settings.flag" echo open
)

rem voice-overlay.py - voice input floating pill (HOLD Ctrl+Win to talk,
rem release to send). Standalone pythonw process, keyboard hotkey is
rem polling-only (no system hook): it never talks to the IME, so it cannot
rem crash WeaselServer. Old instance is stopped first; the script also has a
rem single-instance mutex of its own.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*voice-overlay.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='VoiceOverlay.exe'\" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
if exist "%~dp0VoiceOverlay.exe" (
  start "Rime Voice Overlay" /min "%~dp0VoiceOverlay.exe" >nul 2>&1
  goto :voice_started
)
where pythonw >nul 2>nul
if not errorlevel 1 (
  for /f "delims=" %%p in ('where pythonw 2^>nul') do (
    start "Rime Voice Overlay" /min "%%p" "%~dp0voice-overlay.py" >nul 2>&1
    goto :voice_started
  )
)
echo [warn] VoiceOverlay.exe / pythonw not found - voice overlay not started.
:voice_started

echo Clipboard sync and v-menu supervisor started, settings window opening.
echo   press  v  then  1  in the input method to open the settings window,
echo   or double-click VMenu.exe in this folder to open it directly.
