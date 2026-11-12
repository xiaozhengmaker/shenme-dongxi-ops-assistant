# steam_full.ps1 -- 全量抓取所有 Steam 群成员，直接写入本地 SQLite（不走 CSV，不怕几百万行）
# 用法： powershell -File steam_full.ps1 [-Limit 0] [-DelayMs 250]
# 断点： data\steam_full_state.json（按群记已完成的页码）

param(
  [int]$Limit = 0,
  [int]$DelayMs = 4000,
  [int]$MaxPages = 0
)

$ErrorActionPreference = "Continue"
$baseDir = Split-Path -Parent $PSCommandPath
. (Join-Path $baseDir "lib\feishu.ps1")
. (Join-Path $baseDir "lib\db.ps1")

$logDir = Join-Path $baseDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$script:LogFile = Join-Path $logDir "steam_full.log"
$stateFile = Join-Path $baseDir "data\steam_full_state.json"
$metaFile = Join-Path $baseDir "data\steam_meta.json"
$script:metaAll = @{}
if (Test-Path $metaFile) { try { $mo = Get-Content $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in $mo.PSObject.Properties.Name) { $script:metaAll[$k] = $mo.$k } } catch { } }
function Save-Meta { try { [System.IO.File]::WriteAllText($metaFile, ($script:metaAll | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false))) } catch { } }

$lockFile = Join-Path $baseDir "data\steam.lock"
if (Test-Path $lockFile) {
  $lp = 0; try { $lp = [int]((Get-Content $lockFile -Raw).Trim()) } catch { }
  if ($lp -gt 0 -and @(Get-Process -Id $lp -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "[skip] another steam job running pid=$lp"
    exit 0
  }
}
[System.IO.File]::WriteAllText($lockFile, [string]$PID)
$tmpDir = Join-Path $baseDir "data\tmp_ids"
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }

function Ev([string]$m) {
  try {
    $body = @{ msg = ($m -replace '[^\x20-\x7E]', '?') } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/event' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 5 | Out-Null
  } catch { }
}

function Ev([string]$m) {
  try {
    $b = @{ msg = ($m -replace '[^\x20-\x7E]', '?') } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/event' -Method Post -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec 5 | Out-Null
  } catch { }
}

function Say([string]$msg) {
  $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] " + $msg
  Write-Host $line
  try { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"

$state = @{}
if (Test-Path $stateFile) {
  try {
    $raw = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = [int]$p.Value }
  } catch { }
}
function Save-State {
  $obj = @{}
  foreach ($k in $state.Keys) { $obj[$k] = $state[$k] }
  try { [System.IO.File]::WriteAllText($stateFile, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

# --- 取群清单 ---
$targets = @()
try {
  foreach ($r in (Get-FsRecords)) {
    $plat = [string]$r.fields.'平台'
    if ($plat -ne "Steam") { continue }
    $st = [string]$r.fields.'状态'
    if ($st -eq "已退出" -or $st -eq "已失效") { continue }
    $link = [string]$r.fields.'群链接'
    $name = [string]$r.fields.'群名'
    if ($link -match "steamcommunity\.com/groups/([^/?#]+)") {
      $targets += [pscustomobject]@{ slug = $Matches[1]; name = $name }
    }
  }
} catch { Say ("feishu read failed: " + $_.Exception.Message) }

$targets = @($targets | Sort-Object slug -Unique)
if ($Limit -gt 0) { $targets = @($targets | Select-Object -First $Limit) }
Ev "steam fetch start"
Say ("=== steam_full start, groups=" + $targets.Count + " ===")

$grandTotal = 0
$script:curDelay = if ($DelayMs -gt 0) { $DelayMs } else { 12000 }
$okStreak = 0
foreach ($g in $targets) {
  $slug = $g.slug
  $gname = if ($g.name) { $g.name } else { $slug }
  $startPage = 1
  if ($state.ContainsKey($slug)) { $startPage = [int]$state[$slug] + 1 }
  if ($startPage -lt 1) { $startPage = 1 }

  $meta = $null
  if ($script:metaAll.ContainsKey($slug)) { $meta = $script:metaAll[$slug] }
  $totalPages = 0
  $totalMembers = 0
  if ($meta) { $totalPages = [int]$meta.total; $totalMembers = [int]$meta.members }

  if ($totalPages -le 0) {
    $url1 = "https://steamcommunity.com/groups/$slug/memberslistxml/?xml=1&p=1"
    $txt = $null
    for ($pt = 1; $pt -le 4; $pt++) {
      try {
        $html = Invoke-WebRequest -Uri $url1 -UserAgent $ua -TimeoutSec 30 -UseBasicParsing
        $txt = $html.Content
        break
      } catch {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($code -eq 429) {
          $script:curDelay = [Math]::Min(120000, [Math]::Max(2000, $script:curDelay) * 2)
          Say ("[$slug] probe 429, delay now " + [int]($script:curDelay/1000) + "s, wait " + (90 * $pt) + "s")
          Start-Sleep -Seconds (90 * $pt)
        } else {
          Say ("[$slug] probe err: " + $_.Exception.Message)
          Start-Sleep -Seconds (10 * $pt)
        }
      }
    }
    if (-not $txt) { Say ("[$slug] probe give up"); continue }
    if ($txt -match "<totalPages>(\d+)</totalPages>") { $totalPages = [int]$Matches[1] }
    if ($txt -match "<memberCount>(\d+)</memberCount>") { $totalMembers = [int]$Matches[1] }
    if ($totalPages -gt 0) {
      $script:metaAll[$slug] = @{ total = $totalPages; members = $totalMembers; at = (Get-Date -Format "yyyy-MM-dd") }
      Save-Meta
    }
  } else {
    Say ("[$slug] meta cache hit pages=$totalPages members=$totalMembers")
  }

  if ($totalPages -le 0) { Say ("[$slug] no pages (members=$totalMembers)"); continue }
  $endPage = $totalPages
  if ($MaxPages -gt 0 -and $MaxPages -lt $endPage) { $endPage = $MaxPages }
  if ($startPage -gt $endPage) { Say ("[$slug] already done, skip (page=$startPage end=$endPage)"); continue }
  Say ("[$slug] members=$totalMembers pages=$totalPages from=$startPage to=$endPage")

  $batchStart = $startPage
  for ($p = $startPage; $p -le $endPage; $p++) {
    $url = "https://steamcommunity.com/groups/$slug/memberslistxml/?xml=1&p=$p"
    $content = $null
    for ($try = 1; $try -le 6; $try++) {
      try {
        $resp = Invoke-WebRequest -Uri $url -UserAgent $ua -TimeoutSec 30 -UseBasicParsing
        $content = $resp.Content
        break
      } catch {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($code -eq 429) {
          $wait = 60 * $try
          Say ("[" + $slug + "] 429 rate limited at p=" + $p + ", wait " + $wait + "s (try " + $try + "/6)")
          Start-Sleep -Seconds $wait
        } else {
          Say ("[" + $slug + "] p=" + $p + " err=" + $_.Exception.Message)
          Start-Sleep -Milliseconds (1500 * $try)
        }
      }
    }
    if (-not $content) { Say ("[$slug] page $p failed after retries"); continue }

    $ids = [regex]::Matches($content, "<steamID64>(\d+)</steamID64>") | ForEach-Object { $_.Groups[1].Value }
    if ($ids.Count -gt 0) {
      $tmpFile = Join-Path $tmpDir ("$slug-$p.txt")
      [System.IO.File]::WriteAllLines($tmpFile, @($ids), (New-Object System.Text.UTF8Encoding($false)))
      $r = Invoke-DbTool -Args @("bulk", "Steam", $slug, $gname, $tmpFile)
      try { $obj = $r | ConvertFrom-Json } catch { $obj = $null }
      if ($obj -and $obj.ok) { $grandTotal += [int]$obj.input } else { Say ("[$slug] bulk failed p=$p : " + $r) }
      Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    $state[$slug] = $p
    if (($p - $batchStart + 1) % 10 -eq 0) { Save-State }
    if ($p % 10 -eq 0) { Say ("[$slug] page $p/$endPage ids_so_far=$grandTotal"); Ev ("steam " + $slug + " p=" + $p + "/" + $endPage + " ids=" + $grandTotal) }
    $okStreak++
    if ($okStreak -ge 10) { $script:curDelay = [Math]::Max([Math]::Max(2000,$DelayMs), [int]($script:curDelay / 2)); $okStreak = 0 }
    Start-Sleep -Milliseconds $script:curDelay
  }
  Save-State
  Say ("[$slug] done, total_ids=$grandTotal")
}

Save-State
$st = Get-DbStats
Say ("=== steam_full done, ids=" + $grandTotal + " db_rows=" + $st.rows + " size=" + $st.size_mb + "MB ===")
Ev "steam fetch done"
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
