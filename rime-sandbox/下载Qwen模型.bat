@echo off
chcp 65001 >nul
title Download Qwen3-ASR voice models
cd /d "%~dp0"
rem Downloads the two Qwen3-ASR gguf models next to this script (they are NOT
rem stored in git - each file is larger than the GitHub 100MB hard limit).
rem Sources: https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF
set "BASE=https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main"
set "M1=Qwen3-ASR-0.6B-Q8_0.gguf"
set "M2=mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"

if exist "%~dp0%M1%" if exist "%~dp0%M2%" (
  echo Models already present - nothing to download.
  echo 模型已存在，无需下载。
  pause
  exit /b 0
)

where curl >nul 2>nul
if errorlevel 1 (
  echo curl not found - please download manually from:
  echo   %BASE%
  pause
  exit /b 1
)

if not exist "%~dp0%M1%" (
  echo Downloading %M1% ^(767MB^), please wait ...
  curl -L --retry 3 --retry-delay 2 -C - -o "%~dp0%M1%" "%BASE%/%M1%"
  if errorlevel 1 (
    echo Download failed for %M1%
    pause
    exit /b 1
  )
)
if not exist "%~dp0%M2%" (
  echo Downloading %M2% ^(205MB^), please wait ...
  curl -L --retry 3 --retry-delay 2 -C - -o "%~dp0%M2%" "%BASE%/%M2%"
  if errorlevel 1 (
    echo Download failed for %M2%
    pause
    exit /b 1
  )
)

echo.
echo Done. Models saved to:
echo   %~dp0
pause
exit /b 0
