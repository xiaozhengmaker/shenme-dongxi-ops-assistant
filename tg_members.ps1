param(
  [string]$Username = "",
  [string]$ChatId = "",
  [int]$Max = 3000,
  [int]$PageSize = 200,
  [int]$SpacingMinMs = 900,
  [int]$SpacingMaxMs = 1600,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dataDir = Join-Path $root "data"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
. (Join-Path $root "lib\log.ps1")
$logPath = Join-Path $root "logs\tg_members.log"
Set-LogFile $logPath
$csv = Join-Path $dataDir "users.csv"
$jsonl = Join-Path $dataDir "users.jsonl"
$cursorFile = Join-Path $dataDir "cursor_tg.json"
$fn = [System.IO.File]::ReadAllText((Join-Path $dataDir "tg_page.js"), [System.Text.Encoding]::UTF8)
$aliveJs = [System.IO.File]::ReadAllText((Join-Path $dataDir "tg_alive.js"), [System.Text.Encoding]::UTF8)
$today = (Get-Date).ToString("yyyy/MM/dd")

if (-not (Test-Path $csv)) {
  '平台,群ID,群名,用户ID,用户名,昵称,语言,角色,最近活跃,采集日,来源,状态' | Out-File -FilePath $csv -Encoding utf8
}

# —— 跳过名单：成员列表隐藏的群，直接跳过（data/skip.json） ——
$skipFile = Join-Path $dataDir "skip.json"
$skipKeys = @{}
if (Test-Path $skipFile) {
  try {
    $sj = [System.IO.File]::ReadAllText($skipFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($sj.Telegram) { foreach ($k in $sj.Telegram.PSObject.Properties.Name) { $skipKeys[$k.TrimStart("@").ToLower()] = $sj.Telegram.$k } }
  } catch { }
}
$skipId = ""
if ($Username) { $skipId = $Username.TrimStart("@").ToLower() } elseif ($ChatId) { $skipId = $ChatId.TrimStart("@").ToLower() }
if ($skipId -and $skipKeys.ContainsKey($skipId)) {
  $reason = $skipKeys[$skipId]
  Write-Log "跳过 $skipId（$($reason.reason)，已采样 $($reason.sampled)）" -Level "WARN" -Tag "skip"
  Write-Output ("SKIP " + $skipId + " reason=" + $reason.reason + " sampled=" + $reason.sampled)
  exit 0
}

function EvalJs([string]$expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 8
  $raw = & (Join-Path $root "cdp_call.ps1") -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram.org"
  try { $outer = $raw | ConvertFrom-Json } catch { return $null }
  return $outer.result.value
}

function Test-TgAlive {
  $v = EvalJs $aliveJs
  if ($v -is [string] -and $v.Trim() -eq "alive") { return $true }
  return $false
}

function LoadCursor {
  if (-not (Test-Path $cursorFile)) { return @{} }
  try {
    $o = Get-Content $cursorFile -Encoding UTF8 -Raw | ConvertFrom-Json
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
  } catch { return @{} }
}
function SaveCursor([string]$key, [int]$offset, [int]$collected) {
  $h = LoadCursor
  $h[$key] = [pscustomobject]@{ offset = $offset; collected = $collected; updated = (Get-Date).ToString("s") }
  ($h | ConvertTo-Json -Depth 5) | Out-File -FilePath $cursorFile -Encoding utf8
}

function CallAdmin([hashtable]$arg) {
  $json = ($arg | ConvertTo-Json -Compress -Depth 6)
  $expr = "(" + $fn + ")(" + $json + ")"
  $v = EvalJs $expr
  if (-not $v) { return $null }
  try { return ($v | ConvertFrom-Json) } catch { return $null }
}

$seen = @{}
$key = if ($Username) { "@" + $Username.ToLower() } else { $ChatId }
$collected = 0
if (Test-Path $jsonl) {
  foreach ($line in (Get-Content $jsonl -Encoding UTF8)) {
    if (-not $line) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.group_key -eq $key) { $seen[[string]$o.user_id] = 1; $collected++ }
  }
}
$cursors = LoadCursor
$offset = 0
if ($cursors.ContainsKey($key)) { $offset = [int]$cursors[$key].offset }
Write-Log "start key=$key already=$collected resumeOffset=$offset max=$Max" "INFO" "sampler"

$round = 0
$failStreak = 0
while ($collected -lt $Max -and $round -lt 400) {
  $round++
  if (-not (Test-TgAlive)) {
    SaveCursor $key $offset $collected
    Write-Log "tg session dead before page $round; saved cursor offset=$offset collected=$collected" "ERROR" "sampler"
    Write-Host "RESULT: dead key=$key collected=$collected offset=$offset"
    exit 4
  }
  if ($Username) { $arg = @{ u = $Username; offset = $offset; limit = $PageSize } }
  else { $arg = @{ kind = "channel"; id = [int64]$ChatId; offset = $offset; limit = $PageSize } }
  $r = CallAdmin $arg
  if (-not $r) {
    $failStreak++
    Write-Log "empty response page=$round failStreak=$failStreak" "WARN" "sampler"
    if ($failStreak -ge 3) {
      SaveCursor $key $offset $collected
      Write-Host "RESULT: failed key=$key collected=$collected offset=$offset"
      exit 5
    }
    Start-Sleep -Seconds 2
    continue
  }
  if ($r.err) {
    Write-Log "api error: $($r.err) page=$round" "ERROR" "sampler"
    SaveCursor $key $offset $collected
    Write-Host "RESULT: api_error key=$key err=$($r.err)"
    exit 6
  }
  $failStreak = 0
  $users = @($r.users)
  if ($round -eq 1) { Write-Log "peer=$($r.peer.title) kind=$($r.peer.kind) total=$($r.total)" "INFO" "sampler" }
  $added = 0
  foreach ($u in $users) {
    $uid = [string]$u.id
    if (-not $uid -or $seen.ContainsKey($uid)) { continue }
    $seen[$uid] = 1
    $role = if ($u.admin) { "管理员" } else { "成员" }
    $row = [pscustomobject]@{
      platform = "Telegram"; group_key = $key; group_name = [string]$r.peer.title
      user_id = $uid; username = [string]$u.username; nickname = [string]$u.name
      role = $role; collected_at = $today; source = "getParticipants"
    }
    ($row | ConvertTo-Json -Compress) | Out-File -FilePath $jsonl -Encoding utf8 -Append
    $nm = ([string]$u.name) -replace '"', '""'
    $un = [string]$u.username
    $gn = ([string]$r.peer.title) -replace '"', '""'
    ('"Telegram","' + $key + '","' + $gn + '","' + $uid + '","' + $un + '","' + $nm + '","","' + $role + '","","' + $today + '","getParticipants","有效"') | Out-File -FilePath $csv -Encoding utf8 -Append
    $added++; $collected++
  }
  $offset += $PageSize
  SaveCursor $key $offset $collected
  Write-Log "page=$round got=$($users.Count) added=$added collected=$collected next=$offset done=$($r.done)" "INFO" "sampler"
  if ($r.done -or $users.Count -eq 0) { break }
  if ($DryRun) { break }
  Start-Sleep -Milliseconds (Get-Random -Minimum $SpacingMinMs -Maximum $SpacingMaxMs)
}
Write-Log "finish key=$key collected=$collected rounds=$round" "INFO" "sampler"
Write-Host "RESULT: ok key=$key collected=$collected rounds=$round"