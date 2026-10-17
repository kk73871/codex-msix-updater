@echo off
setlocal
set "SCRIPT=%~dp0CodexMsixUpdater.ps1"
if not exist "%SCRIPT%" (
  echo 找不到 CodexMsixUpdater.ps1
  pause
  exit /b 2
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo 此工具需要 Windows PowerShell 5.1。
  pause
  exit /b 3
)
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b %ERRORLEVEL%
