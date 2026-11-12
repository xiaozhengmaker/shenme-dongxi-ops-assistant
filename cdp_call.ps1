param(
  [Parameter(Mandatory=$true)][string]$Method,
  [string]$ParamsJson = "{}",
  [string]$TargetId = "",
  [int]$Port = 0,
  [int]$TimeoutSec = 40,
  [string]$Match = "feishu\\.cn",
  [string]$Out = ""
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

$paramsObj = $ParamsJson | ConvertFrom-Json
$payload = @{ id = 1; method = $Method; params = $paramsObj } | ConvertTo-Json -Depth 12 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(10000) | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$buf = New-Object byte[] 8388608
$result = $null
while ((Get-Date) -lt $deadline) {
  if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
  $sb = New-Object System.Text.StringBuilder
  do {
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
    $task = $ws.ReceiveAsync($seg, $ct)
    try {
      if (-not $task.Wait(20000)) { Write-Output "ERR: recv timeout"; $ws.Dispose(); exit 6 }
    } catch {
      $ie = $_.Exception
      while ($ie.InnerException) { $ie = $ie.InnerException }
      Write-Output ("ERR: recv " + $ie.GetType().Name + ": " + $ie.Message)
      $ws.Dispose(); exit 5
    }
    $res = $task.Result
    [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
  } while (-not $res.EndOfMessage)

  $txt = $sb.ToString()
  if ([string]::IsNullOrWhiteSpace($txt)) { continue }
  $obj = $txt | ConvertFrom-Json
  if ($obj.id -eq 1) {
    if ($obj.error) { Write-Output ("ERR: " + ($obj.error | ConvertTo-Json -Compress)); $ws.Dispose(); exit 3 }
    $result = $obj.result
    break
  }
}
$ws.Dispose()
if ($null -eq $result) { Write-Output "ERR: timeout"; exit 4 }

if ($Out -ne "") {
  $b64 = $result.data
  if ($b64) {
    [System.IO.File]::WriteAllBytes($Out, [System.Convert]::FromBase64String($b64))
    Write-Output ("OK: wrote " + $Out + " (" + (Get-Item $Out).Length + " bytes)")
  } else {
    Write-Output ("ERR: no data field; keys=" + (($result.PSObject.Properties.Name) -join ","))
  }
} else {
  $result | ConvertTo-Json -Depth 12 -Compress
}
