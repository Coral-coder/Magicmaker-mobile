@echo off
title MagicMaker ESP32 flasher
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash.ps1" %*
echo.
pause
