@echo off
setlocal
set "TMPPS=%TEMP%\Install-Domlight-v137-%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/Install-Domlight-v137.ps1' -OutFile '%TMPPS%' -TimeoutSec 45 } catch { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(('Не удалось скачать установщик.'+[Environment]::NewLine+[Environment]::NewLine+$_.Exception.Message),'Domlight Clean Install','OK','Error') | Out-Null; exit 1 }"
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%"
del /q "%TMPPS%" >nul 2>&1
endlocal
