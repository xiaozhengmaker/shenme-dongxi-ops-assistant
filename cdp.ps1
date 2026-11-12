param(
  [string]$TargetId = "",
  [string]$Expr = "document.title",
  [int]$Port = 0,
  [int]$TimeoutSec = 40,
  [string]$Match = "feishu\\.cn"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\paths.ps1")
if ($Port -le 0) { $Port = (Get-GOpsPort (Get-GOpsConfig)) }
$list = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($TargetId)) {
  $t = $list | Where-Object { $_.type -eq "page" -and $_.url -match $Match } | Select-Object -First 1
  if (-not $t) { $t = $list | Where-Object { $_.type -eq "page" } | Select-Object -First 1 }
} else {
  $t = $list | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
}
if (-not $t) { Write-Output "ERR: target not found"; exit 2 }

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null

$payload = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = $Expr; returnByValue = $true; awaitPromise = $true } } | ConvertTo-Json -Depth 6 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(10000) | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$buf = New-Object byte[] 1048576
$result = $null
while ((Get-Date) -lt $deadline) {
  if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
  $sb = New-Object System.Text.StringBuilder
  do {
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
    $task = $ws.ReceiveAsync($seg, $ct)
    if (-not $task.Wait(5000)) { break }
    $res = $task.Result
    [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
  } while (-not $res.EndOfMessage)

  $txt = $sb.ToString()
  if ([string]::IsNullOrWhiteSpace($txt)) { continue }
  $obj = $txt | ConvertFrom-Json
  if ($obj.id -eq 1) {
    if ($obj.result -and $obj.result.exceptionDetails) {
      Write-Output ("ERR: " + $obj.result.exceptionDetails.text)
      $ws.Dispose(); exit 3
    }
    $result = $obj.result.result.value
    break
  }
}
$ws.Dispose()
if ($null -eq $result) { Write-Output "ERR: timeout"; exit 4 }
$result
