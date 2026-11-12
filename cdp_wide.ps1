param(
  [int]$Width = 2600,
  [int]$Height = 900,
  [int]$Port = 0,
  [string]$Match = "feishu",
  [Parameter(Mandatory=$true)][string]$Out
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\paths.ps1")
if ($Port -le 0) { $Port = (Get-GOpsPort (Get-GOpsConfig)) }
$list = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
$t = $list | Where-Object { $_.type -eq "page" -and $_.url -match $Match } | Select-Object -First 1
if (-not $t) { Write-Output "ERR: target not found"; exit 2 }

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait(10000) | Out-Null
$buf = New-Object byte[] 8388608

function Send-Cdp($id, $method, $params) {
  $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
  $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(10000) | Out-Null
}

function Read-Cdp($wantId) {
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
      $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$script:buf)
      $task = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
      if (-not $task.Wait(25000)) { return $null }
      $res = $task.Result
      [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($script:buf, 0, $res.Count))
      if ($res.EndOfMessage) { break }
    }
    $txt = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($txt)) { continue }
    $obj = $txt | ConvertFrom-Json
    if ($obj.id -eq $wantId) { return $obj }
  }
  return $null
}

Send-Cdp 1 "Emulation.setDeviceMetricsOverride" @{ width = $Width; height = $Height; deviceScaleFactor = 1; mobile = $false }
Read-Cdp 1 | Out-Null
Start-Sleep -Milliseconds 2500
Send-Cdp 2 "Page.captureScreenshot" @{ format = "png"; captureBeyondViewport = $false }
$r = Read-Cdp 2
if ($r -and $r.result.data) {
  [System.IO.File]::WriteAllBytes($Out, [System.Convert]::FromBase64String($r.result.data))
  Write-Output ("OK: " + $Out + " " + (Get-Item $Out).Length + " bytes")
} else {
  Write-Output "ERR: no screenshot"
}
Send-Cdp 3 "Emulation.clearDeviceMetricsOverride" @{}
Read-Cdp 3 | Out-Null
$ws.Dispose()
