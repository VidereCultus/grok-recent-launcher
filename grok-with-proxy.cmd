@echo off
setlocal
set "HTTP_PROXY=http://127.0.0.1:7890"
set "HTTPS_PROXY=http://127.0.0.1:7890"
set "ALL_PROXY=http://127.0.0.1:7890"
set "NO_PROXY=localhost,127.0.0.1,::1"

set "GROK_EXE=%USERPROFILE%\.grok\bin\grok.exe"
if not exist "%GROK_EXE%" (
  echo 找不到 grok.exe: %GROK_EXE%
  exit /b 1
)

"%GROK_EXE%" %*
