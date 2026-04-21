@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

echo.
echo   ========================================
echo     V-Claw Core Bundle Producer Build
echo     Canonical Windows bundle artifact flow
echo   ========================================
echo.

set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\build-core-bundles-win.ps1" -Clean %*
exit /b %ERRORLEVEL%
