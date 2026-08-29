@echo off
setlocal
set "TMPPS=%TEMP%\Install-Domlight-v149-%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/Install-Domlight-v149.ps1' -OutFile '%TMPPS%' -TimeoutSec 45 } catch { exit 1 }"
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%"
del /q "%TMPPS%" >nul 2>&1
endlocal
