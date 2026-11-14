# run_all.ps1 -- 一键全流程：拓群(多平台) -> 成员采样 -> 人数回填 -> Steam 抽样导入 -> 可选日报
# 由看板「开始运行」触发（hub /control {"action":"pipeline"}），也可手动跑。
param(
  [string[]]$Platforms = @("Telegram","Facebook","Reddit"),
  [switch]$SkipMembers,
  [switch]$SkipSteam,
  [switch]$Report,
  [switch]$NoReport,
  [switch]$Fast,
  [int]$WaitTimeoutMin = 90
)

$ErrorActionPreference = "Continue"
$baseDir = Split-Path -Parent $PSCommandPath
$hubUrl = "http://127.0.0.1:8787"
$logDir = Join-Path $baseDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$script:LogFile = Join-Path $logDir "run_all.log"
function Say([string]$msg) {
  $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] " + $msg
  Write-Host $line
  try { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  try {
    $body = @{ msg = $msg } | ConvertTo-Json -Compress
    Invoke-RestMethod "$hubUrl/api/event" -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
  } catch { }
}

function Hub([string]$method, [string]$path, $body) {
  if ($method -eq "GET") { return Invoke-RestMethod ($hubUrl + $path) -TimeoutSec 15 }
  $json = $body | ConvertTo-Json -Compress
  return Invoke-RestMethod ($hubUrl + $path) -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20
}

Say "=== run_all 开始 ==="
$fail = @()

# 0) 前台体检
$chk = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "check.ps1") 2>&1
$chkLast = ($chk | Select-Object -Last 1)
Say ("check.ps1 -> " + $chkLast)
if ($chkLast -notmatch "可以开工") {
  Say "自检未通过，中止（先处理红灯）"
  exit 3
}

# 1) 逐平台拓群
# -File 传参会把 "Telegram,Facebook,Reddit" 当成单个字符串，这里拆开
$Platforms = @($Platforms | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Platforms = @($Platforms | Where-Object { $cfgPlatforms -or $true })
foreach ($p in $Platforms) {
  if (Test-GOpsStop $baseDir) { Say 'stop flag -> 退出'; exit 0 }
  if ($SkipMembers -and $false) { }
  Say ("--- 平台 " + $p + " 拓群开始")
  try { Hub "POST" "/control" @{ action = "start"; platform = $p } | Out-Null } catch { Say ("启动失败 " + $p + "：" + $_.Exception.Message); $fail += $p; continue }
  $deadline = (Get-Date).AddMinutes($WaitTimeoutMin)
  $lastPhase = ""
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $h = Hub "GET" "/health" $null
    if ($h.phase -ne $lastPhase) { $lastPhase = $h.phase; Say ("  " + $p + " phase=" + $h.phase) }
    if (-not $h.running) { break }
  }
  if ($h.running) { Say ("  " + $p + " 超时，跳过"); $fail += $p }
  else { Say ("--- 平台 " + $p + " 拓群完成") }
}

# 2) 成员采样 + 人数回填
if (-not $SkipMembers) {
  Say "--- TG 成员采样"
  $out = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "tg_members_all.ps1") 2>&1
  ($out | Select-String "TOTAL|SKIP|RESULT" | Select-Object -Last 3) | ForEach-Object { Say ("  " + $_.Line) }

  Say "--- 人数回填（含隐藏名单）"
  $out2 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "tg_fix_counts.ps1") -IncludeHidden 2>&1
  ($out2 | Select-String "UPDATED|targets=" | Select-Object -Last 2) | ForEach-Object { Say ("  " + $_.Line) }
}

# 3) Steam 抽样 + 导入成员样本
if (-not $SkipSteam) {
  Say "--- Steam 成员抽样"
  $pages = 1
  if ($Fast) { $pages = 1 }
  $out3 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "steam_sample_all.ps1") -MaxPages $pages 2>&1
  ($out3 | Select-String "DONE|WROTE|fail" | Select-Object -Last 3) | ForEach-Object { Say ("  " + $_.Line) }

  Say "--- 导入成员样本"
  $out4 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "steam_to_users.ps1") 2>&1
  ($out4 | Select-String "CSV VIEW|WROTE" | Select-Object -Last 2) | ForEach-Object { Say ("  " + $_.Line) }
}

# 3.5) 同步到本地数据库
if (-not $SkipSteam) {
  Say "--- 同步到本地数据库"
  try {
    . (Join-Path $baseDir "lib\db.ps1")
    Initialize-LocalDb | Out-Null
    $dbr = Import-LocalDb -CsvPaths @((Join-Path $baseDir "data\users.csv"))
    Say ("  db rows imported = " + $dbr.imported)
  } catch { Say ("  db sync failed: " + $_.Exception.Message) }
}

# 4) 日报：默认在跑完后发（-NoReport 可跳过；-Report 保留兼容）
$autoReport = (-not $NoReport) -or $Report
if ($autoReport) {
  Say "--- 发日报"
  $out5 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "report_all.ps1") 2>&1
  ($out5 | Select-String "webhook|合计|failed|error" | Select-Object -Last 3) | ForEach-Object { Say ("  " + $_.Line) }
}

try { Hub "POST" "/control" @{ action = "stop" } | Out-Null } catch { }
if ($fail.Count -gt 0) { Say ("=== run_all 结束，失败平台：" + ($fail -join ",") + " ==="); exit 4 }
Say "=== run_all 全部完成 ==="