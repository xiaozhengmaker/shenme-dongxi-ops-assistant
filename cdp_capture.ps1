param(
  [int]$Port = 0,
  [int]$Seconds = 15,
  [string]$Filter = "bitable",
  [switch]$NoReload
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\paths.ps1")
if ($Port -le 0) { $Port = (Get-GOpsPort (Get-GOpsConfig)) }
$list = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
$t = $list | Where-Object { $_.type -eq "page" -and $_.url -match "feishu\.cn" } | Select-Object -First 1
if (-not $t) { Write-Output "ERR: no feishu page tab"; exit 2 }

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null

function Send-Msg($obj) {
  $json = $obj | ConvertTo-Json -Depth 8 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(10000) | Out-Null
}

Send-Msg @{ id = 1; method = "Network.enable"; params = @{} }
Start-Sleep -Milliseconds 400
if (-not $NoReload) {
  Send-Msg @{ id = 2; method = "Page.reload"; params = @{ ignoreCache = $false } }
}

$deadline = (Get-Date).AddSeconds($Seconds)
$buf = New-Object byte[] 2097152
$seen = New-Object System.Collections.Specialized.OrderedDictionary
$pat = $Filter

while ((Get-Date) -lt $deadline) {
  if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
  $sb = New-Object System.Text.StringBuilder
  do {
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
    $task = $ws.ReceiveAsync($seg, $ct)
    if (-not $task.Wait(1500)) { $res = $null; break }
    $res = $task.Result
    [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
  } while (-not $res.EndOfMessage)

  $txt = $sb.ToString()
  if ([string]::IsNullOrWhiteSpace($txt)) { continue }

  foreach ($line in ($txt -split "(?<=\})\s*(?=\{)")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.method -ne "Network.requestWillBeSent") { continue }
    $req = $o.params.request
    if (-not $req) { continue }
    if ($req.url -notmatch $pat) { continue }
    $key = $req.method + " " + $req.url
    if (-not $seen.Contains($key)) {
      $body = ""
      if ($req.postData) { $body = ($req.postData -replace "\s+", " ") }
      $seen[$key] = $body
    }
  }
}
$ws.Dispose()

foreach ($k in $seen.Keys) {
  $v = $seen[$k]
  if ($v) { Write-Output ("$k`n    BODY: " + $v.Substring(0, [Math]::Min(600, $v.Length))) }
  else { Write-Output $k }
}
Write-Output ("--- captured " + $seen.Count + " unique requests")
