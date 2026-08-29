@echo off
cd /d "%~dp0"
set "TASKNAME=Domlight Auto Check"
set "SCRIPT=%~dp0RunAutoCheckHidden.ps1"

rem Remove legacy pre-release tasks only.
schtasks /Delete /TN "Domlight DEV Auto Check" /F >nul 2>&1
schtasks /Delete /TN "Domlight RC Auto Check" /F >nul 2>&1

schtasks /Create /TN "%TASKNAME%" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%SCRIPT%\"" /SC HOURLY /MO 6 /F

if errorlevel 1 (
  echo.
  echo Could not enable automatic checking.
  echo Try right-clicking this file and choose "Run as administrator".
  pause
  exit /b 1
)

echo.
echo Automatic checking is ON.
echo Windows will check Domlight every 6 hours while this computer is available.
echo.
pause
