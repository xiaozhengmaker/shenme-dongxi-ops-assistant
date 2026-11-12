# run_daily.ps1 —— 由 Windows 计划任务每天触发：确保 hub 在跑，然后开始一轮采集
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $here "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir "daily.log"

function Log($m) {
  $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  " + $m
  Add-Content -Path $log -Value $line -Encoding UTF8
}

$alive = $false
try {
  $h = Invoke-RestMethod "http://127.0.0.1:8787/health" -TimeoutSec 4
  $alive = $true
  Log ("hub alive, phase=" + $h.phase)
} catch {
  Log "hub not running, starting"
}

if (-not $alive) {
  Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $here "hub.ps1")
  ) -WindowStyle Hidden
  Start-Sleep -Seconds 10
}

try {
  $cfg = Get-Content (Join-Path $here "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  $plats = @($cfg.platforms)
  foreach ($p in $plats) {
    $q = 0
    if ($cfg.quotas.PSObject.Properties.Name -contains $p) { $q = [int]$cfg.quotas.$p }
    if ($q -le 0) { Log ("skip " + $p + " (quota 0)"); continue }
    $body = @{ action = "start"; platform = $p } | ConvertTo-Json -Compress
    Invoke-RestMethod "http://127.0.0.1:8787/control" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15 | Out-Null
    Log ("started " + $p + " quota=" + $q)
    Start-Sleep -Seconds 3
  }
} catch {
  Log ("start failed: " + $_.Exception.Message)
}

# ---- platform_dispatch：非 hub 平台（Steam / Reddit / WhatsApp）按行为与目标跑各自脚本 ----
function Get-Beh($plat, $key) {
  try { return [bool]$cfg.behaviors.$plat.$key } catch { return $false }
}
$py = "powershell.exe"
$q = $cfg.quotas
if ($cfg.behaviors.Steam -and (Get-Beh "Steam" "join")) {
  $sq = Join-Path $here "data\steam_queue.txt"
  $n = [int]$q.Steam
  if ((Test-Path $sq) -and $n -gt 0) {
    $targets = @(Get-Content $sq -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith("#") } | Select-Object -First $n)
    foreach ($g in $targets) {
      Log ("steam join " + $g)
      & $py -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "steam_join.ps1") -Group $g *>> $log
      Start-Sleep -Seconds 600
    }
  }
}
if ($cfg.behaviors.Reddit -and (Get-Beh "Reddit" "discover")) {
  $rn = [int]$q.Reddit
  if ($rn -gt 0) {
    Log ("reddit run maxSubs=" + $rn)
    & $py -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "rd_run.ps1") -MaxSubs $rn *>> $log
  }
}
if ($cfg.behaviors.WhatsApp -and (Get-Beh "WhatsApp" "join")) {
  $wl = Join-Path $here "data\wa_links_cs2.csv"
  $wn = [int]$q.WhatsApp
  if ((Test-Path $wl) -and $wn -gt 0) {
    $codes = @(Import-Csv $wl | Select-Object -First $wn)
    foreach ($row in $codes) {
      $code = $row.code
      if (-not $code) { $code = $row.link -replace ".*chat\.whatsapp\.com/", "" }
      if (-not $code) { continue }
      Log ("whatsapp accept " + $code)
      & $py -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "wa_members.ps1") -AcceptCode $code *>> $log
      Start-Sleep -Seconds 600
    }
  }
}

