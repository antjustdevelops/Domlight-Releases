@echo off
setlocal
set "PS=%TEMP%\MeterFormInspector-%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/tools/meter-form-inspector/tools/meter-form-inspector/MeterFormInspector.ps1' -OutFile '%PS%' -TimeoutSec 45 } catch { exit 1 }"
if errorlevel 1 (
 echo Cannot download Meter Form Inspector.
 pause
 exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS%"
set "RC=%ERRORLEVEL%"
del /q "%PS%" >nul 2>&1
exit /b %RC%
