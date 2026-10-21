@echo off
setlocal

rem mpv --register writes HKLM (all users) when elevated, HKCU otherwise.
rem Always elevate, so register/unregister always operate on the same scope.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "MPVCOM=%~dp0..\mpv.com"
set "MPVEXE=%~dp0..\mpv.exe"

if not exist "%MPVCOM%" if not exist "%MPVEXE%" (
    echo ========================================
    echo [ERROR] mpv.com / mpv.exe not found:
    echo   %~dp0..
    echo ========================================
    pause
    exit /b 1
)

if exist "%MPVCOM%" (
    "%MPVCOM%" --config=no --register
) else (
    "%MPVEXE%" --config=no --register
)
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo ========================================
    echo [ERROR] Registration failed. Exit code: %RC%
    echo Make sure mpv.com and mpv.exe are in:
    echo   %~dp0..
    echo ========================================
    pause
    exit /b %RC%
)

echo ========================================
echo Registered successfully (all users).
echo Do not move mpv.exe. If you move this folder,
echo run this script again to re-register.
echo ========================================
pause
exit /b 0
