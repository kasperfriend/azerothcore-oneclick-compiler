@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "SCRIPT=%~dp0Compile-AzerothCore-Playerbots.ps1"
if not exist "%SCRIPT%" (
  echo ERROR: Compile-AzerothCore-Playerbots.ps1 must be beside this BAT file.
  pause
  exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting Administrator rights...
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $a='/d /c call '+$q+'%~f0'+$q; Start-Process -FilePath $env:ComSpec -Verb RunAs -ArgumentList $a"
  if errorlevel 1 (
    echo ERROR: Administrator elevation could not be started.
    pause
    exit /b 1
  )
  exit /b 0
)

echo Starting AzerothCore compiler...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "ERR=%errorlevel%"
echo.
if not "%ERR%"=="0" (
  echo Compilation/setup returned error %ERR%.
  echo Check the error above and the logs folder.
) else (
  echo Compiler finished successfully.
)
pause
exit /b %ERR%
