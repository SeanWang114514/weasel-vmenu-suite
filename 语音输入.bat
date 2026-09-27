@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 语音输入
if exist "%~dp0VoiceInput.exe" (
  "%~dp0VoiceInput.exe"
) else (
  python "%~dp0voice-input.py"
)
if errorlevel 1 pause
