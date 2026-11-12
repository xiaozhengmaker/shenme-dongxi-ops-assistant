param(
  [int]$MinHits = 2,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = "D:\DeepSeek\运营"
$dataDir = Join-Path $root "data"
$poolDir = Join-Path $dataDir "pools"
$statsPath = Join-Path $poolDir "kwstats.json"
$cfgPath = Join-Path $root "config.json"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$utf8bom = New-Object System.Text.UTF8Encoding($true)

# 1) 收集所有候选池里的关键词命中（hub 写的 data\pool_*.json + 互推写的 data\pools\candidates_*.json）
$hits = @{}
$files = @()
$files += Get-ChildItem $dataDir -Filter "pool_*.json" -ErrorAction SilentlyContinue
$files += Get-ChildItem $poolDir -Filter "candidates_*.json" -ErrorAction SilentlyContinue

foreach ($f in $files) {
  try { $o = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
  $plat = [string]$o.platform
  if (-not $plat) { $plat = ($f.BaseName -replace "^pool_", "" -replace "^candidates_", "") }
  foreach ($it in @($o.items)) {
    $q = [string]$it.q
    if (-not $q -or $q -eq "crosslink") { continue }
    $key = $plat + "|" + $q
    if (-not $hits.ContainsKey($key)) { $hits[$key] = @{ platform = $plat; kw = $q; hits = 0 } }
    $hits[$key].hits++
  }
}

# 2) 与历史统计合并
$stats = @{}
if (Test-Path $statsPath) {
  try { $stats = [System.IO.File]::ReadAllText($statsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -AsHashtable } catch { $stats = @{} }
}
if (-not $stats) { $stats = @{} }
foreach ($k in $hits.Keys) {
  $cur = if ($stats.ContainsKey($k)) { [int]$stats[$k].hits } else { 0 }
  $stats[$k] = @{ platform = $hits[$k].platform; kw = $hits[$k].kw; hits = $cur + $hits[$k].hits }
}

$promoted = New-Object System.Collections.ArrayList
$cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$poolWords = New-Object System.Collections.ArrayList
foreach ($w in @($cfg.keywordPool)) { [void]$poolWords.Add([string]$w) }
$poolLower = @{}
foreach ($w in $poolWords) { $poolLower[$w.ToLower()] = 1 }

foreach ($k in ($stats.Keys | Sort-Object { -[int]$stats[$_].hits })) {
  $s = $stats[$k]
  if ([int]$s.hits -lt $MinHits) { continue }
  if ($poolLower.ContainsKey(([string]$s.kw).ToLower())) { continue }
  [void]$promoted.Add($s.kw)
}

"STATS: $($stats.Count) entries, files=$($files.Count)"
$top = $stats.Keys | Sort-Object { -[int]$stats[$_].hits } | Select-Object -First 8
foreach ($k in $top) { "  $($stats[$k].platform) / $($stats[$k].kw) = $($stats[$k].hits)" }
"PROMOTE candidates: $($promoted.Count)"
foreach ($p in $promoted) { "  + $p" }

if ($DryRun) { exit 0 }

[System.IO.File]::WriteAllText($statsPath, ($stats | ConvertTo-Json -Depth 6), $utf8)

if ($promoted.Count -gt 0) {
  foreach ($p in $promoted) { [void]$poolWords.Add($p) }
  $cfg.keywordPool = $poolWords.ToArray()
  [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 12), $utf8bom)
  "WROTE: config.keywordPool -> $($poolWords.Count) 词"
} else {
  "no promotion"
}
