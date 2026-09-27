@echo off
chcp 65001 >nul
rem Start (or restart) the voice-input floating pill (hold Ctrl+Win to talk).
rem ASCII-only on purpose: cmd.exe decodes .bat with the active code page.
rem The overlay is a standalone pythonw process; it never touches the IME.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*voice-overlay.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='VoiceOverlay.exe'\" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
if exist "%~dp0VoiceOverlay.exe" (
  start "" "%~dp0VoiceOverlay.exe"
  echo Voice overlay started. HOLD Ctrl+Win to talk, RELEASE to send.
  goto :eof
)
where pythonw >nul 2>nul
if not errorlevel 1 (
  for /f "delims=" %%p in ('where pythonw 2^>nul') do (
    start "" "%%p" "%~dp0voice-overlay.py"
    echo Voice overlay started. HOLD Ctrl+Win to talk, RELEASE to send.
    goto :eof
  )
)
echo [warn] VoiceOverlay.exe / pythonw not found - voice overlay not started.
