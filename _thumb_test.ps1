param(
  [string]$WithProxy = "no",
  [int]$StartSec = 60
)
$mpvpath = "E:\mpv-lazy\mpv.exe"
$out = Join-Path $env:TEMP "thumb_probe.out"
Remove-Item $out -ErrorAction SilentlyContinue

if ($WithProxy -eq "yes") {
  $env:HTTP_PROXY = "http://127.0.0.1:10809"
  $env:HTTPS_PROXY = "http://127.0.0.1:10809"
  $env:http_proxy  = "http://127.0.0.1:10809"
  $env:https_proxy = "http://127.0.0.1:10809"
} else {
  Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:http_proxy, Env:https_proxy -ErrorAction SilentlyContinue
}

$proxyEnv = if ($WithProxy -eq "yes") { $env:HTTP_PROXY } else { "(none)" }
Write-Host "mpv=$mpvpath  PROXY=$WithProxy ($proxyEnv)"

$mpvArgs = @(
  "--config=no",
  "--terminal=no", "--msg-level=all=warn",
  "--idle=yes", "--keep-open=always", "--pause=yes", "--ao=null",
  "--osc=no", "--load-stats-overlay=no", "--load-console=no",
  "--autoload-files=no",
  "--vid=auto", "--sub=no", "--audio=no",
  "--start=$StartSec",
  "--ytdl=yes", "--ytdl-format=worstvideo/worst",
  "--vf=scale=w=320:h=320:format=fmt=bgra",
  "--ovc=rawvideo", "--of=image2", "--ofopts=update=1", "--o=$out",
  "--input-ipc-server=thumb_probe",
  "--",
  "https://www.bilibili.com/video/BV1aptt6uEGs/"
)

& $mpvpath @mpvArgs 2>&1 | Out-Null

$deadline = (Get-Date).AddSeconds(20)
$frame = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if (Test-Path $out) { $frame = Get-Item $out; break }
}
if ($frame) {
  Write-Host ("RESULT PROXY={0} -> FRAME size={1}" -f $WithProxy, $frame.Length)
} else {
  Write-Host ("RESULT PROXY={0} -> NO FRAME" -f $WithProxy)
}