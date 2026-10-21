@echo off
setlocal

rem mpv --unregister removes the registration of the scope matching the
rem current privileges. Elevate, so an all-users (HKLM) registration is
rem always removed. Then drop per-user leftovers from earlier runs.
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
    "%MPVCOM%" --config=no --unregister
) else (
    "%MPVEXE%" --config=no --unregister
)
set "RC=%errorlevel%"

rem Extra cleanup: entries written by a previous non-elevated --register.
reg delete "HKCU\Software\Classes\Applications\mpv.exe" /f >nul 2>&1
reg delete "HKCU\Software\Classes\io.mpv.file" /f >nul 2>&1
reg delete "HKCU\Software\Classes\io.mpv.url" /f >nul 2>&1
reg delete "HKCU\Software\Clients\Media\mpv" /f >nul 2>&1
reg delete "HKCU\Software\RegisteredApplications" /v "mpv" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe" /f >nul 2>&1

if not "%RC%"=="0" (
    echo ========================================
    echo [ERROR] Unregistration failed. Exit code: %RC%
    echo Make sure mpv.com and mpv.exe are in:
    echo   %~dp0..
    echo ========================================
    pause
    exit /b %RC%
)

echo ========================================
echo Unregistered successfully.
echo ========================================
pause
exit /b 0
