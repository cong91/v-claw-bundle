@echo off
chcp 65001 >nul 2>&1
setlocal

if "%~1"=="" (
  echo Usage: %~nx0 ^<version^> ^<path-to-u-claw-v-claw-app^>
  echo Example: %~nx0 1.0.0 ..\V-Claw\v-claw-app
  exit /b 1
)
if "%~2"=="" (
  echo Usage: %~nx0 ^<version^> ^<path-to-u-claw-v-claw-app^>
  echo Example: %~nx0 1.0.0 ..\V-Claw\v-claw-app
  exit /b 1
)

set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\build-core-bundles-win.ps1" -Version "%~1" -Source "%~2"
exit /b %ERRORLEVEL%
