@echo off
chcp 65001 >nul
rem Open the visual settings window for the Weasel v-menu feature.
rem The window process is normally already resident (kept alive by
rem vmenu-watcher.ps1). In that case this launch only asks it to show itself
rem and exits right away, so the window appears instantly.
rem ASCII-only source on purpose: cmd.exe decodes a .bat with the active code
rem page and desyncs on multi-byte characters split across read buffers.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0vmenu-settings-gui.ps1" -RimeDir "D:\rime-sandbox" -ShowNow
