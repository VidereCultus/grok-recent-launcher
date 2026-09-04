@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0创建桌面快捷方式.ps1"
if errorlevel 1 (
  echo.
  echo 创建失败。
  pause
  exit /b 1
)
echo.
echo 桌面会出现「Grok 最近项目」。双击即可。
pause
