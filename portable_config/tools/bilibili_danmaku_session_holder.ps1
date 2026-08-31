param(
    [Parameter(Mandatory = $true)][string]$PipeName,
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

$ErrorActionPreference = 'Stop'
$client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
$client.Connect(5000)
$encoding = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($client, $encoding, 1024, $true)
$writer.AutoFlush = $true
$reader = [System.IO.StreamReader]::new($client, $encoding, $false, 1024, $true)
$requestId = 1

function Invoke-MpvCommand([object[]]$Command) {
    $script:requestId++
    $writer.WriteLine((@{ command = $Command; request_id = $script:requestId } | ConvertTo-Json -Compress))
    do {
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw 'mpv IPC closed' }
        $response = $line | ConvertFrom-Json
    } while ($response.request_id -ne $script:requestId)
    return $response
}

Invoke-MpvCommand @('load-script', $ScriptPath) | Out-Null
while ($true) {
    Start-Sleep -Seconds 2
    Invoke-MpvCommand @('get_property', 'idle-active') | Out-Null
}
