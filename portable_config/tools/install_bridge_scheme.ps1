# One-time setup: register custom URI scheme 'bilibili-mpv://' so the relay
# userscript can auto-start bilibili_parse_bridge from the browser button.
# - No admin required (HKCU).
# - Re-run this script after moving/renaming the mpv-lazy folder.
# - Uninstall: Remove-Item 'HKCU:\Software\Classes\bilibili-mpv' -Recurse

$ErrorActionPreference = 'Stop'

$toolsDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $toolsDir)
$pythonw     = Join-Path $projectRoot 'pythonw.exe'
$bridge      = Join-Path $toolsDir 'bilibili_parse_bridge.py'

if (-not (Test-Path $pythonw) -or -not (Test-Path $bridge)) {
    Write-Host "ERROR: missing files. pythonw=$pythonw bridge=$bridge" -ForegroundColor Red
    exit 1
}

$command = '"' + $pythonw + '" "' + $bridge + '"'

$schemeRoot = 'HKCU:\Software\Classes\bilibili-mpv'
New-Item -Path $schemeRoot -Force | Out-Null
New-Item -Path "$schemeRoot\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $schemeRoot -Name '(Default)' -Value 'URL:bilibili-mpv Protocol'
Set-ItemProperty -Path $schemeRoot -Name 'URL Protocol' -Value ''
Set-ItemProperty -Path "$schemeRoot\shell\open\command" -Name '(Default)' -Value $command

Write-Host "OK: registered bilibili-mpv:// -> $command" -ForegroundColor Green
