param(
  [Parameter(Mandatory=$true)][int]$X,
  [Parameter(Mandatory=$true)][int]$Y,
  [Parameter(Mandatory=$true)][string]$Text,
  [int]$Port = 0,
  [string]$Match = "feishu\\.cn",
  [switch]$NoPaste
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\paths.ps1")
if ($Port -le 0) { $Port = (Get-GOpsPort (Get-GOpsConfig)) }
Set-Clipboard -Value $Text

$list = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
$t = $list | Where-Object { $_.type -eq "page" -and $_.url -match $Match } | Select-Object -First 1
if (-not $t) { Write-Output "ERR: target not found"; exit 2 }

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null

function Send-Cdp($ws, $id, $method, $params) {
  $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
  $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(10000) | Out-Null
}

$buf = New-Object byte[] 1048576
function Read-Cdp($ws, $wantId) {
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    $sb = New-Object System.Text.StringBuilder
    do {
      $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$script:buf)
      $task = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
      try { if (-not $task.Wait(8000)) { return $null } } catch { return $null }
      $res = $task.Result
      [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($script:buf, 0, $res.Count))
    } while (-not $res.EndOfMessage)
    $txt = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($txt)) { continue }
    $obj = $txt | ConvertFrom-Json
    if ($obj.id -eq $wantId) { return $obj }
  }
  return $null
}

# 1) click the cell
Send-Cdp $ws 1 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $X; y = $Y; button = "left"; clickCount = 1 }
Send-Cdp $ws 2 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $X; y = $Y; button = "left"; clickCount = 1 }
Start-Sleep -Milliseconds 400

if (-not $NoPaste) {
  # 2) ctrl+v
  Send-Cdp $ws 3 "Input.dispatchKeyEvent" @{ type = "rawKeyDown"; modifiers = 2; key = "v"; code = "KeyV"; windowsVirtualKeyCode = 86; nativeVirtualKeyCode = 86 }
  Send-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyUp"; modifiers = 2; key = "v"; code = "KeyV"; windowsVirtualKeyCode = 86; nativeVirtualKeyCode = 86 }
}

Start-Sleep -Milliseconds 1200
$r = Read-Cdp $ws 4
$ws.Dispose()
Write-Output ("clicked " + $X + "," + $Y + " paste=" + (-not $NoPaste) + " chars=" + $Text.Length)
