# tools/backfill_names.ps1 - 按池内同 u 精确匹配回填空群名；不匹配留待核
$ErrorActionPreference = "Stop"
$baseDir = Split-Path $PSScriptRoot -Parent
. (Join-Path $baseDir "lib\feishu.ps1")

$poolPath = Join-Path $baseDir "data\pool_telegram.json"
$pool = @()
if (Test-Path $poolPath) {
  $pj = Get-Content $poolPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($pj.items) { $pool = @($pj.items) }
}

$nameByU = @{}
$nameByH = @{}
foreach ($it in $pool) {
  $t = [string]$it.t; if (-not $t) { $t = [string]$it.title }
  if (-not $t.Trim()) { continue }
  $u = ([string]$it.u).Trim()
  if ($u) { $nameByU[$u.ToLower()] = $t.Trim() }
  $h = ([string]$it.h).Trim()
  if ($h) { $nameByH[$h] = $t.Trim() }
}
Write-Host ("pool={0} nameByU={1} nameByH={2}" -f $pool.Count, $nameByU.Count, $nameByH.Count)

$all = @(Get-FsRecords)
Write-Host ("feishu_rows=" + $all.Count)

$updates = @()
$pending = @()
foreach ($r in $all) {
  $f = $r.fields
  if ([string]$f."平台" -ne "Telegram") { continue }
  $nm = ([string]$f."群名").Trim()
  if ($nm) { continue }

  $key = [string]$f."群组唯一键"
  $u = ""
  if ($key -match "^TG-(.+)$") { $u = $Matches[1] }
  $gid = [string]$f."群ID"

  $hit = ""
  if ($u -and $nameByU.ContainsKey($u.ToLower())) { $hit = $nameByU[$u.ToLower()] }
  if (-not $hit -and $gid -and $nameByH.ContainsKey($gid)) { $hit = $nameByH[$gid] }

  if ($hit) {
    $updates += @{ record_id = $r.record_id; fields = @{ "群名" = $hit } }
    Write-Host ("MATCH {0} {1} gid={2} -> {3}" -f $r.record_id, $key, $gid, $hit)
  } else {
    $pending += [pscustomobject]@{ record_id = $r.record_id; key = $key; gid = $gid }
  }
}

Write-Host ("matched={0} pending={1}" -f $updates.Count, $pending.Count)
if ($updates.Count -gt 0) {
  $n = Update-FsRecords -Updates $updates
  Write-Host ("updated=" + $n)
}
if ($pending.Count -gt 0) {
  $pending | Export-Csv -Path (Join-Path $baseDir "data\name_pending.csv") -NoTypeInformation -Encoding UTF8
  Write-Host "pending list -> data\name_pending.csv"
}

$after = @(Get-FsRecords)
Write-Host ("feishu_rows_after=" + $after.Count)
