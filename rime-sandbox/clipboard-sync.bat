@echo off
chcp 65001 >nul
start "Rime Clipboard Sync" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0clipboard-sync.ps1"
