param(
    [string]$ExtensionId = 'gikjlcfdnjgmdbdnefmknkpndmkfdlhf'
)

$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'publish_v13\mpv-cookie-bridge.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Bridge executable is missing: $exe" }
$manifest = Join-Path $PSScriptRoot 'com.mpv_lazy.cookie_bridge.json'
@{
    name = 'com.mpv_lazy.cookie_bridge'
    description = 'mpv Chrome Cookie Bridge (in-memory only)'
    path = $exe
    type = 'stdio'
    allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 3 | ForEach-Object {
    [IO.File]::WriteAllText($manifest, $_, [Text.UTF8Encoding]::new($false))
}

$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mpv_lazy.cookie_bridge'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name '(Default)' -Value $manifest
Write-Output "Native host registered for extension $ExtensionId"
