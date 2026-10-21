@echo off

setlocal enableextensions enabledelayedexpansion
path %SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0

:: Unattended flag. When set, the script will not pause at the end.
set unattended=no
if "%1"=="/u" set unattended=yes

:: This script needs administrator rights, self-elevate if needed.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "classes_root_key=HKLM\SOFTWARE\Classes"

:: Delete "App Paths" entry
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\umpv.exe" /f >nul 2>&1

:: Delete HKCR subkeys
reg delete "%classes_root_key%\Applications\umpv.exe" /f >nul 2>&1
reg delete "%classes_root_key%\SystemFileAssociations\video\OpenWithList\umpv.exe" /f >nul 2>&1
reg delete "%classes_root_key%\SystemFileAssociations\audio\OpenWithList\umpv.exe" /f >nul 2>&1

:: Delete "Default Programs" entry (value and its whole capability tree)
reg delete "HKLM\SOFTWARE\RegisteredApplications" /v "umpv" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Clients\Media\umpv" /f >nul 2>&1

:: Delete per-user leftovers (Explorer "Open with" / previous non-elevated runs)
reg delete "HKCU\Software\Classes\Applications\umpv.exe" /f >nul 2>&1
reg delete "HKCU\Software\Classes\umpv_auto_file" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\umpv.exe" /f >nul 2>&1

:: Delete all OpenWithProgIds values referencing ProgIds that start with io.umpv.
for /f "usebackq eol= delims=" %%k in (`reg query "%classes_root_key%" /f "io.umpv.*" /s /v /c`) do (
    set "key=%%k"
    echo !key!| findstr /r /i "^HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\\.[^\\][^\\]*\\OpenWithProgIds$" >nul
    if not errorlevel 1 (
        for /f "usebackq eol= tokens=1" %%v in (`reg query "!key!" /f "io.umpv.*" /v /c`) do (
            set "value=%%v"
            echo !value!| findstr /r /i "^io\.umpv\.[^\\][^\\]*$" >nul
            if not errorlevel 1 (
                echo Deleting !key!\!value!
                reg delete "!key!" /v "!value!" /f >nul 2>&1
            )
        )
    )
)

:: Delete all ProgIds starting with io.umpv.
for /f "usebackq eol= delims=" %%k in (`reg query "%classes_root_key%" /f "io.umpv.*" /k /c`) do (
    set "key=%%k"
    echo !key!| findstr /r /i "^HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\io\.umpv\.[^\\][^\\]*$" >nul
    if not errorlevel 1 (
        echo Deleting !key!
        reg delete "!key!" /f >nul 2>&1
    )
)

:: Delete start menu link
del /f /q "%ProgramData%\Microsoft\Windows\Start Menu\Programs\umpv.lnk" >nul 2>&1

echo Unregistered successfully.
if [%unattended%] == [yes] exit /b 0
pause
exit /b 0
