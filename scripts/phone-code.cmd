@echo off
chcp 65001 >nul
setlocal
title Phone VS Code (openvscode-server)
echo Connecting to the device and opening the VS Code tunnel...
echo.
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo [ERROR] bash.exe not found. Install Git for Windows, or edit BASH in this file.
  pause
  exit /b 1
)
"%BASH%" -lc "cd \"$(cygpath -u '%~dp0')\" && ./phone-code.sh"
if errorlevel 1 (
  echo.
  echo [ERROR] Tunnel is NOT running - see the messages above.
  pause
  exit /b 1
)
echo.
echo Open the URL printed above. Closing this window is safe.
pause
