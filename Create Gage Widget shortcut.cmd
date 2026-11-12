@echo off
rem Double-click to put a Gage Widget shortcut on the desktop. Keep this file with gage-widget.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Create Gage Widget shortcut.ps1"
if errorlevel 1 pause
