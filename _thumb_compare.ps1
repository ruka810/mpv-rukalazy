param(
  [string]$WithProxy = "no",
  [int]$WaitSec = 30
)
# 用与 handler 相同的 env / 启动参数，测试缩略图是否生成
$mpvcom = "E:\mpv-lazy\mpv.com"
$ipc = "mpvtest_$(Get-Random)"

if ($WithProxy -eq "yes") {
  $env:HTTP_PROXY = "http://127.0.0.1:10809"
  $env:HTTPS_PROXY = "http://127.0.0.1:10809"
  $env:http_proxy  = "http://127.0.0.1:10809"
  $env:https_proxy = "http://127.0.0.1:10809"
} else {
  Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:http_proxy, Env:https_proxy -ErrorAction SilentlyContinue
}

# 复刻 handler：cookie bridge + quality
$mpvArgs = @(
  "--input-ipc-server=$ipc",
  "--ytdl-raw-options-append=format-sort=res:720,+vcodec:h264",
  "--script-opts=ytdl_hook-ytdl_path=E:\mpv-lazy\portable_config\tools\chrome_cookie_bridge\publish_v13\mpv-cookie-bridge.exe",
  "--",
  "https://www.bilibili.com/video/BV1aptt6uEGs/"
)

$p = Start-Process -FilePath $mpvcom -ArgumentList $mpvArgs -PassThru -WindowStyle Hidden
$comPid = $p.Id
Write-Host "PROXY=$WithProxy comPid=$comPid ipc=$ipc"
# 等待主播放器加载完成（出现 IPC 管道）
$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline) {
  if (Test-Path ("\\.\pipe\" + $ipc)) { break }
  Start-Sleep -Milliseconds 500
}
# 找到实际 mpv.exe（脚本进程）PID
$mpvPid = $comPid
Start-Sleep -Seconds 1
$child = Get-CimInstance Win32_Process -Filter "Name='mpv.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $comPid }
if ($child) { $mpvPid = $child.ProcessId }
Write-Host "PROXY=$WithProxy mpv.exePid=$mpvPid"
Start-Sleep -Seconds 8   # 等 yt-dlp 解析与加载
# 注入悬停
function SendMpvJson($pipe, $cmd) {
  try {
    $p2 = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    $p2.Connect(2000)
    $sw = New-Object System.IO.StreamWriter($p2, [Text.Encoding]::UTF8)
    $json = '{"command": [' + $cmd + '], "request_id": 1}' + "`n"
    $sw.Write($json); $sw.Flush(); $sw.BaseStream.Flush()
    $sr = New-Object System.IO.StreamReader($p2, [Text.Encoding]::UTF8)
    $t = $sr.ReadLineAsync()
    if ($t.Wait(2000)) { return $t.Result } else { return "(no-reply)" }
  } catch { return ("ERR " + $_.Exception.Message) }
}
SendMpvJson $ipc '"script-message","thumbnail_gen","60","400","200"' | Out-Null
# 轮询缩略图输出文件
$thumbFile = "$env:TEMP\thumb_engine.out$mpvPid"
$found = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 600
  if (Test-Path $thumbFile) { $fi = Get-Item $thumbFile; Write-Host "PROXY=$WithProxy THUMB FOUND size=$($fi.Length)"; $found=$true; break }
}
if (-not $found) { Write-Host "PROXY=$WithProxy -> NO THUMB FILE" }
Stop-Process -Id $mpvPid -Force -ErrorAction SilentlyContinue