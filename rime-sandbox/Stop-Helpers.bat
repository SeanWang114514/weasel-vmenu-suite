@echo off
rem Stop the background helpers so their files can be replaced.
rem Used by the exe installer (PrepareToInstall) and for manual repairs.
rem ASCII-only: cmd.exe decodes .bat with the active code page.
set "RIME_DIR=%~dp0"
if exist "%RIME_DIR%VMenu.exe" "%RIME_DIR%VMenu.exe" stop >nul 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='pythonw.exe'\" | Where-Object { $_.CommandLine -like '*voice-overlay.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='VoiceOverlay.exe'\" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='VoiceInput.exe'\" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
rem llama-server maps the .gguf ASR models; while it runs, those files cannot be
rem replaced by the installer (re-install would fail / roll back). Kill it too and
rem let the voice overlay start a fresh one on demand.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='llama-server.exe'\" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
exit /b 0
