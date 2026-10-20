@echo off
rem Opens the OpenCaptureLink window. It asks for administrator rights so links work in all apps.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0OpenCaptureLink.ps1" -Gui
