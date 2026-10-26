@echo off
rem Double-click entry point: opens the unlock window without leaving a console.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GpuUnlock.ps1" -Gui
