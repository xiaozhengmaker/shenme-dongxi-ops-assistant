# sidepanel_recovery.ps1 — 侧边栏动态回归（真实 Chrome + 真实 JS）
# 目的：同一页面 从「两个通道都失败」-> 「live 先恢复、status 仍失败」-> 「两个通道都恢复，按钮恢复可用」
# 依赖：Chrome 调试端口（默认 9222）、cdp_call.ps1、tests\live\stub_recover.js
# 不会触碰 hub 业务与真实数据：桩完全在页面内替换 chrome.runtime / fetch。
param([int]$Port = 9222, [string]$RunDir = "D:\DeepSeek\运营")
$ErrorActionPreference = "Stop"
$cdp = Join-Path $RunDir "cdp_call.ps1"
$src = Join-Path $RunDir "extension\src"
$stubSrc = Join-Path $PSScriptRoot "stub_recover.js"

$fx = Join-Path $env:TEMP ("sidepanel_live_" + (Get-Date -Format "HHmmss"))
New-Item -ItemType Directory -Force -Path $fx | Out-Null
foreach ($f in @("sidepanel.html", "sidepanel.js", "sidepanel.css")) {
  Copy-Item (Join-Path $src $f) (Join-Path $fx $f) -Force
}
Copy-Item $stubSrc (Join-Path $fx "stub.js") -Force

$hp = Join-Path $fx "sidepanel.html"
$h = [System.IO.File]::ReadAllText($hp, [System.Text.Encoding]::UTF8)
if (-not $h.Contains("stub.js")) {
  $h = $h.Replace('<script src="sidepanel.js"></script>', '<script src="stub.js"></script>' + "`r`n" + '  <script src="sidepanel.js"></script>')
}
[System.IO.File]::WriteAllText($hp, $h, (New-Object System.Text.UTF8Encoding($true)))

$url = "file:///" + ($fx -replace '\\', '/') + "/sidepanel.html"
$tab = (Invoke-WebRequest -Method Put ("http://127.0.0.1:$Port/json/new?" + [uri]::EscapeDataString($url)) -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
$drv = '(function(){var t=function(s){var e=document.querySelector(s);return e?(e.innerText||"").replace(/\s+/g," ").trim().slice(0,60):null;};var dis=[].slice.call(document.querySelectorAll("button")).filter(function(x){return x.disabled;}).map(function(x){return x.id;});return JSON.stringify({hub:t("#hubText"),phase:t("#phase"),liveState:t("#liveState"),disabled:dis.join(",")});})()'
$pj = @{ expression = $drv; returnByValue = $true } | ConvertTo-Json -Compress

function Snap {
  $out = (& $cdp -Method "Runtime.evaluate" -ParamsJson $pj -TargetId $tab.id -TimeoutSec 20 2>&1 | Out-String)
  $m = [regex]::Match($out, '"value"\s*:\s*"((?:[^"\\]|\\.)*)"')
  if ($m.Success) { return [System.Text.RegularExpressions.Regex]::Unescape($m.Groups[1].Value) }
  return $out.Trim()
}

$fails = 0
function T([bool]$ok, [string]$n, [string]$d = "") { if ($ok) { "PASS $n" } else { "FAIL $n  $d"; $script:fails++ } }

try {
  Start-Sleep -Seconds 6
  $a = Snap
  Start-Sleep -Seconds 4
  $b = Snap
  Start-Sleep -Seconds 8
  $c = Snap
} finally {
  try { Invoke-WebRequest "http://127.0.0.1:$Port/json/close/$($tab.id)" -UseBasicParsing -TimeoutSec 6 | Out-Null } catch {}
}

"T1 6s  : $a"
"T2 10s : $b"
"T3 18s : $c"

$j1 = $a | ConvertFrom-Json
$j2 = $b | ConvertFrom-Json
$j3 = $c | ConvertFrom-Json

T ($j1.hub -eq "扩展未响应") "T1 status 通道失败：hubText=扩展未响应"
T ($j1.disabled -match "btnStart") "T1 status 失败时：开始按钮被禁用"
T ([string]$j1.liveState -ne "") "T1 live 通道独立：仍有自身状态文案（$($j1.liveState)）"
T ($j2.liveState -ne "" -and $j2.hub -ne "") "T2 两通道可不同步（live=$($j2.liveState) / hub=$($j2.hub)）"
T ($j3.phase -ne "—") "T3 status 恢复：phase 不再是 —（$($j3.phase)）"
T ($j3.disabled -notmatch "btnStart") "T3 恢复后：开始按钮重新可用（disabled=$($j3.disabled)）"

if ($fails -gt 0) { "SIDEPANEL RECOVERY: $fails FAILED"; exit 1 }
"SIDEPANEL RECOVERY: all PASS"
