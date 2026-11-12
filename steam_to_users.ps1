# steam_to_users.ps1 -- 把 data\steam_users.csv 的 Steam 群成员并入成员样本 data\users.jsonl
# 只做幂等追加（按 platform|group_key|user_id 去重），不删不改已有行。
param([string]$CsvPath = "", [switch]$DryRun)

$baseDir = Split-Path -Parent $PSCommandPath
$dataDir = Join-Path $baseDir "data"
if (-not $CsvPath) { $CsvPath = Join-Path $dataDir "steam_users.csv" }
$jsonl = Join-Path $dataDir "users.jsonl"

if (-not (Test-Path $CsvPath)) { Write-Host ("missing csv: " + $CsvPath); exit 2 }

$csvView = Join-Path $dataDir "users.csv"
$csvHeader = "平台,群ID,群名,用户ID,用户名,昵称,角色,采集日,来源"
$csvKeys = @{}
if (Test-Path $csvView) {
  try { foreach ($c in (Import-Csv $csvView -Encoding UTF8)) { $csvKeys[([string]$c."平台") + "|" + ([string]$c."群ID") + "|" + ([string]$c."用户ID")] = 1 } } catch { }
}

$existing = @{}
$total = 0
if (Test-Path $jsonl) {
  foreach ($line in (Get-Content $jsonl -Encoding UTF8)) {
    if (-not $line) { continue }
    $total++
    try {
      $o = $line | ConvertFrom-Json
      $existing[([string]$o.platform) + "|" + ([string]$o.group_key) + "|" + ([string]$o.user_id)] = 1
    } catch { }
  }
}
Write-Host ("existing rows=" + $total + " unique keys=" + $existing.Count)

$rows = Import-Csv $CsvPath -Encoding UTF8
$added = 0
$dup = 0
$bad = 0
$lines = New-Object System.Collections.Generic.List[string]
$csvLines = New-Object System.Collections.Generic.List[string]
foreach ($r in $rows) {
  $gid = [string]$r."群ID"
  $sid = [string]$r."SteamID64"
  if (-not $gid -or -not $sid) { $bad++; continue }
  $k = "Steam|" + $gid + "|" + $sid
  $day0 = [string]$r."采集日"
  if ($day0 -match "^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$") { $day0 = $Matches[1] + "/" + ([int]$Matches[2]).ToString("00") + "/" + ([int]$Matches[3]).ToString("00") }
  if (-not $csvKeys.ContainsKey($k)) {
    $csvKeys[$k] = 1
    $gname = (([string]$r."群名") -replace '"','""')
    $csvLines.Add('Steam,"' + $gid + '","' + $gname + '","' + $sid + '","","","","' + $(if ($r."角色") { [string]$r."角色" } else { "成员" }) + '","","' + $day0 + '","' + $(if ($r."来源") { [string]$r."来源" } else { "群成员XML" }) + '","有效"')
  }
  if ($existing.ContainsKey($k)) { $dup++; continue }
  $existing[$k] = 1
  $day = [string]$r."采集日"
  if ($day -match "^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$") { $day = $Matches[1] + "/" + ([int]$Matches[2]).ToString("00") + "/" + ([int]$Matches[3]).ToString("00") }
  $obj = [ordered]@{
    platform = "Steam"; group_key = $gid; group_id = $gid; group_name = [string]$r."群名"
    user_id = $sid; username = ""; nickname = ""; lang = ""
    role = $(if ($r."角色") { [string]$r."角色" } else { "成员" })
    last_active = $null; collected_at = $day
    source = $(if ($r."来源") { [string]$r."来源" } else { "群成员XML" }); status = "有效"
  }
  $lines.Add(($obj | ConvertTo-Json -Compress -Depth 4))
  $added++
}

Write-Host ("csv rows=" + $rows.Count + " addable=" + $added + " dup=" + $dup + " bad=" + $bad)
if ($DryRun) { Write-Host "DryRun: nothing written"; exit 0 }
if ($lines.Count -gt 0) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $sw = New-Object System.IO.StreamWriter($jsonl, $true, $enc)
  try { foreach ($l in $lines) { $sw.WriteLine($l) } } finally { $sw.Close() }
}
Write-Host ("WROTE: " + $jsonl + " +" + $added + " -> total " + ($total + $added))

# 同步追加到 users.csv（后台 /users 页读的是它）
if ($csvLines.Count -gt 0) {
  $sb = New-Object System.Text.StringBuilder
  if (-not (Test-Path $csvView)) { [void]$sb.AppendLine($csvHeader) }
  foreach ($cl in $csvLines) { [void]$sb.AppendLine($cl) }
  $enc2 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($csvView, $sb.ToString(), $enc2)
}
Write-Host ("CSV VIEW: " + $csvView + " +" + $csvLines.Count)
