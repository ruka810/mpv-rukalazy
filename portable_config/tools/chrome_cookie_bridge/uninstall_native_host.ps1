$key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.mpv_lazy.cookie_bridge'
Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'com.mpv_lazy.cookie_bridge.json') -Force -ErrorAction SilentlyContinue
Write-Output 'Native host registration removed'
