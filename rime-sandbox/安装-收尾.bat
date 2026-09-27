@echo off
chcp 65001 >nul
rem Thin wrapper: all real post-install logic lives in 安装-收尾.ps1
rem (PowerShell handles paths / registry / process control far more reliably).
rem No pause here - 安装.bat and the exe installer show the result themselves.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0安装-收尾.ps1"
exit /b %errorlevel%
