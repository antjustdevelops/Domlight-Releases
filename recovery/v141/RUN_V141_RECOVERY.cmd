@echo off
setlocal
title Domlight v141 Recovery
set "PS1=%TEMP%\INSTALL_V141_RECOVERY_V2.ps1"
echo Domlight v141 Recovery
echo ======================
echo Downloading verified recovery installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/v141-recovery-candidate/recovery/v141/INSTALL_V141_RECOVERY_V2.ps1' -OutFile '%PS1%'"
if errorlevel 1 goto fail
echo Running recovery...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo RECOVERY FINISHED SUCCESSFULLY.
) else (
  echo RECOVERY STOPPED WITH ERROR. Production installation should remain or be rolled back.
)
echo.
echo Press any key to close this window.
pause >nul
exit /b %RC%
:fail
echo.
echo DOWNLOAD FAILED. Nothing was changed.
echo Press any key to close this window.
pause >nul
exit /b 1
