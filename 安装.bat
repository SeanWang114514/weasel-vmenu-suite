@echo off
chcp 65001 >nul
title Rime VMenu package installer / 全家桶安装
setlocal enabledelayedexpansion

rem ===========================================================================
rem One-click full install for the zip package.
rem   1) copy this whole package into the Rime user directory
rem      (env RIME_DIR override -> registry RimeUserDir -> %APPDATA%\Rime)
rem   2) run the post-install steps (安装-收尾.bat):
rem      autostart, tray menu entry, background services, voice overlay,
rem      deploy + restart WeaselServer.
rem
rem Copying is retry-based: security software (on-access scan) may briefly lock
rem freshly extracted .bat/.exe files; we retry robocopy and verify the
rem critical files landed before declaring failure.
rem ===========================================================================

if not defined RIME_DIR for /f "tokens=2*" %%a in ('reg query "HKCU\SOFTWARE\Rime\Weasel" /v RimeUserDir 2^>nul') do set "RIME_DIR=%%b"
if not defined RIME_DIR set "RIME_DIR=%APPDATA%\Rime"

set "SRC=%~dp0"
set "SRCT=%SRC%"
if "%SRCT:~-1%"=="\" set "SRCT=%SRCT:~0,-1%"

if /i "%SRCT%"=="%RIME_DIR%" goto post

echo [1/3] Copying package files to:
echo        %RIME_DIR%
echo        (about 1.2 GB; a retry is normal if antivirus scans the files)

set "RCOPY_OPTS=/E /NFL /NDL /NJH /NJS /NP /R:3 /W:2"
robocopy "%SRCT%" "%RIME_DIR%" %RCOPY_OPTS%
set "RCOPY=!errorlevel!"
if !RCOPY! LSS 8 goto verify

echo        first pass reported a lock - waiting 3 seconds and retrying ...
ping -n 4 127.0.0.1 >nul
robocopy "%SRCT%" "%RIME_DIR%" %RCOPY_OPTS%
set "RCOPY=!errorlevel!"
if !RCOPY! LSS 8 goto verify

:verify
rem robocopy exit >= 8 can still mean "everything copied but one file's
rem attributes could not be set" - check the critical files really exist.
if not exist "%RIME_DIR%\rime_ice.schema.yaml" goto copy_failed
if not exist "%RIME_DIR%\VMenu.exe" goto copy_failed
if not exist "%RIME_DIR%\VoiceOverlay.exe" goto copy_failed
if not exist "%RIME_DIR%\安装-收尾.bat" goto copy_failed
if not exist "%RIME_DIR%\lua\vmenu_core.lua" goto copy_failed
if not exist "%RIME_DIR%\cn_dicts\mydict.dict.yaml" goto copy_failed
echo        critical files verified OK.
echo.
goto post

:copy_failed
echo.
echo [ERROR] copy incomplete - critical files missing in %RIME_DIR%.
echo         Check whether antivirus blocked the copy, then run 安装.bat again.
pause
exit /b 1

:post
echo [2/3] Post-install steps ...
if exist "%RIME_DIR%\安装-收尾.bat" (
  call "%RIME_DIR%\安装-收尾.bat"
) else (
  echo [ERROR] missing: %RIME_DIR%\安装-收尾.bat
  pause
  exit /b 1
)

echo.
echo [3/3] Install finished. Press any key to close.
pause >nul
exit /b 0
