param(
  [string[]]$Keywords = @("cs2","csgo","counter-strike skins","cs2 trading","csgo trading","cs2 market","csgo trade"),
  [int]$MaxPages = 3,
  [int]$MinMembers = 1000,
  [int]$DelayMs = 3000,
  [int]$Limit = 0
)
$ErrorActionPreference = "Continue"
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cdp = Join-Path $baseDir "cdp_call.ps1"
$logDir = Join-Path $baseDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "steam_discover.log"
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

function Say([string]$m) {
  $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $m
  Write-Host $line
  [System.IO.File]::AppendAllText($script:logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Ev([string]$m) {
  try {
    $b = @{ msg = ($m -replace '[^\x20-\x7E]', '?') } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/event' -Method Post -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec 5 | Out-Null
  } catch { }
}

$jsText = [System.IO.File]::ReadAllText((Join-Path $baseDir "data\steam_search.js"), [System.Text.Encoding]::UTF8)
$candFile = Join-Path $baseDir "data\steam_candidates.json"
$known = @{}
if (Test-Path $candFile) {
  try {
    $old = Get-Content $candFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($it in @($old)) { if ($it.slug) { $known[$it.slug] = $true } }
  } catch { }
}
# 排除已入库的群
try {
  . (Join-Path $baseDir "lib\feishu.ps1")
  foreach ($r in (Get-FsRecords)) {
    if ([string]$r.fields."平台" -ne "Steam") { continue }
    $u = [string]$r.fields."群链接"
    $m = [regex]::Match($u, "steamcommunity\.com/groups/([^/?#]+)")
    if ($m.Success) { $known[$m.Groups[1].Value] = $true }
  }
} catch { }

$lockFile = Join-Path $baseDir "data\steam.lock"
if (Test-Path $lockFile) {
  $lp = 0; try { $lp = [int]((Get-Content $lockFile -Raw).Trim()) } catch { }
  if ($lp -gt 0 -and @(Get-Process -Id $lp -ErrorAction SilentlyContinue).Count -gt 0) {
    Say "another steam job running, exit"
    exit 0
  }
}
[System.IO.File]::WriteAllText($lockFile, [string]$PID)
Ev "steam discover start"
Say ("keywords=" + ($Keywords -join ",") + " pages=" + $MaxPages)

$slugs = New-Object System.Collections.ArrayList
foreach ($kw in $Keywords) {
  for ($p = 1; $p -le $MaxPages; $p++) {
    $url = "https://steamcommunity.com/search/groups/?text=" + [uri]::EscapeDataString($kw) + "&p=" + $p
    try {
      & $cdp -Method "Page.navigate" -ParamsJson (@{ url = $url } | ConvertTo-Json -Compress) -Match "search/groups" | Out-Null
      & $cdp -Method "Page.bringToFront" -ParamsJson "{}" -Match "search/groups" | Out-Null
      Start-Sleep -Milliseconds 2500
      $raw = & $cdp -Method "Runtime.evaluate" -ParamsJson (@{ expression = $jsText; returnByValue = $true } | ConvertTo-Json -Compress -Depth 5) -Match "search/groups"
      $outer = $raw | ConvertFrom-Json
      $inner = $outer.result.value | ConvertFrom-Json
      foreach ($s in @($inner.slugs)) { if ($s -and -not $slugs.Contains($s)) { [void]$slugs.Add($s) } }
      Say ("kw=" + $kw + " p=" + $p + " got=" + @($inner.slugs).Count + " total=" + $slugs.Count)
    } catch {
      Say ("kw=" + $kw + " p=" + $p + " err=" + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 800
  }
}

$new = @()
foreach ($s in $slugs) { if (-not $known.ContainsKey($s)) { $new += $s } }
Say ("unique=" + $slugs.Count + " new=" + $new.Count)
if ($Limit -gt 0 -and $new.Count -gt $Limit) { $new = $new[0..($Limit-1)] }

$out = New-Object System.Collections.ArrayList
foreach ($s in $new) {
  $url = "https://steamcommunity.com/groups/" + $s + "/memberslistxml/?xml=1&p=1"
  $txt = $null
  for ($t = 1; $t -le 4; $t++) {
    try {
      $resp = Invoke-WebRequest -Uri $url -UserAgent $ua -TimeoutSec 30 -UseBasicParsing
      $txt = $resp.Content
      break
    } catch {
      $code = 0
      try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
      if ($code -eq 429) { Say ("429 on " + $s + ", wait " + (60*$t) + "s"); Start-Sleep -Seconds (60*$t) }
      else { Say ("err " + $s + ": " + $_.Exception.Message); Start-Sleep -Seconds (5*$t) }
    }
  }
  if (-not $txt) { continue }
  if ($txt -match "<error>(.*?)</error>") { Say ("skip " + $s + " : " + $Matches[1]); continue }
  $mc = 0
  if ($txt -match "<memberCount>(\d+)</memberCount>") { $mc = [int]$Matches[1] }
  $nm = $s
  if ($txt -match "<groupName><!\[CDATA\[(.*?)\]\]></groupName>") { $nm = $Matches[1] }
  elseif ($txt -match "<groupName>(.*?)</groupName>") { $nm = $Matches[1] }
  if ($mc -lt $MinMembers) { Say ("skip " + $s + " members=" + $mc); continue }
  [void]$out.Add([pscustomobject]@{ slug = $s; name = $nm; members = $mc; found = (Get-Date -Format "yyyy-MM-dd") })
  Say ("cand " + $s + " " + $mc)
  Start-Sleep -Milliseconds $DelayMs
}

$all = @()
if (Test-Path $candFile) {
  try { $all = @(Get-Content $candFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $all = @() }
}
$all = @($all) + @($out)
$all = $all | Sort-Object members -Descending
[System.IO.File]::WriteAllText($candFile, ($all | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
Say ("=== steam_discover done, new_candidates=" + $out.Count + " total=" + @($all).Count + " ===")
Ev ("steam discover done new=" + $out.Count)
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
