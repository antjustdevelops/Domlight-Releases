@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ConfigureAutoCheckTask.ps1"
if errorlevel 1 (
  echo.
  echo Could not enable automatic checking.
  echo Try right-clicking this file and choose "Run as administrator".
  pause
  exit /b 1
)
echo.
echo Automatic checking is ON.
echo Missed runs will start when Windows becomes available.
echo A single check is limited to 15 minutes and parallel runs are blocked.
echo.
pause
