@echo off
rem Open the visual settings window for the Weasel v-menu feature.
rem
rem Primary path: VMenu.exe (GUI subsystem exe, NO console window) - it writes the
rem flag file AND makes sure the supervisor is running, so nothing black flashes.
rem Kept ASCII-only on purpose: cmd.exe decodes a .bat with the active code page
rem and desyncs on multi-byte characters split across read buffers.
rem Resolve the Rime user dir: env override -> registry -> %APPDATA%\Rime.
if not defined RIME_DIR for /f "tokens=2*" %%a in ('reg query "HKCU\SOFTWARE\Rime\Weasel" /v RimeUserDir 2^>nul') do set "RIME_DIR=%%b"
if not defined RIME_DIR set "RIME_DIR=%APPDATA%\Rime"

if exist "%~dp0VMenu.exe" (
  "%~dp0VMenu.exe" open
  exit /b 0
)

rem Fallback when VMenu.exe is missing: write the flag by hand and start the
rem PowerShell supervisor (this path can flash one console window).
>"%RIME_DIR%\open-settings.flag" echo open
start "Rime V-Menu Watcher" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0vmenu-watcher.ps1" -RimeDir "%RIME_DIR%" >nul 2>&1
