@echo off
start "" /min powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GrokRecent.ps1"
