@echo off
setlocal EnableExtensions EnableDelayedExpansion

for %%I in ("%~dp0..") do set "ROOT=%%~fI"

if not exist "%ROOT%\portable_config\mpv.conf" (
    echo [ERROR] portable_config not found.
    echo         Put this script in the installer folder of mpv-rukalazy.
    echo.
    pause
    exit /b 1
)

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%i"
if "%STAMP%"=="" set "STAMP=manual"

set "DEST=%ROOT%\_backup\config-%STAMP%"
mkdir "%DEST%\portable_config" >nul 2>nul
mkdir "%DEST%\portable_config\scripts" >nul 2>nul

set "COUNT=0"
echo Backing up personal settings...
echo.

for %%F in (mpv.conf script-opts.conf input_uosc.conf menu.conf profiles.conf saved-props.json live-favorites.json) do (
    if exist "%ROOT%\portable_config\%%F" (
        copy /y "%ROOT%\portable_config\%%F" "%DEST%\portable_config\%%F" >nul
        echo   + portable_config\%%F
        set /a COUNT+=1
    )
)

if exist "%ROOT%\portable_config\scripts\bilibili_danmaku_state.conf" (
    copy /y "%ROOT%\portable_config\scripts\bilibili_danmaku_state.conf" "%DEST%\portable_config\scripts\" >nul
    echo   + portable_config\scripts\bilibili_danmaku_state.conf
    set /a COUNT+=1
)

echo.
if "%COUNT%"=="0" (
    echo [WARN] Nothing to back up.
) else (
    echo Backed up %COUNT% file^(s^) to:
    echo   %DEST%
    echo.
    echo To restore: copy each file back to the same relative path under portable_config.
)
echo.
pause
