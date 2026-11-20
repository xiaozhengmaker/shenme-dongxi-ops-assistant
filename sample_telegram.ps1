# sample_telegram.ps1 -- one explicit Telegram group, existing logged-in session, no joins.
param(
  [string]$Target = "",
  [switch]$Trial,
  [int]$MaxRuntimeMin = 45,
  [int]$PageDelayMs = 1200
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
. (Join-Path $root "lib\member_sample.ps1")
Clear-MemberStop $root "telegram"

$dataDir = Join-Path $root "data"
$fnPath = Join-Path $dataDir "tg_page.js"
$fn = ""
if (Test-Path $fnPath) { $fn = [System.IO.File]::ReadAllText($fnPath, [System.Text.Encoding]::UTF8) }
$csv = Join-Path $dataDir "users.csv"
$jsonl = Join-Path $dataDir "users.jsonl"
$seenPath = Join-Path (Get-MemberDir $root) "telegram_seen.json"
$seen = @{}
if (Test-Path $seenPath) {
  try {
    $o = [System.IO.File]::ReadAllText($seenPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) { $seen[[string]$p.Name] = [int]$p.Value }
  } catch { }
}
if (-not (Test-Path $csv)) {
  '平台,群ID,群名,用户ID,用户名,昵称,语言,角色,最近活跃,采集日,来源,状态' | Out-File -FilePath $csv -Encoding utf8
}
function Save-Seen {
  try {
    $tmp = $seenPath + ".tmp." + [guid]::NewGuid().ToString("N")
    [System.IO.File]::WriteAllText($tmp, ($seen | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $seenPath -Force
  } catch { }
}
function Eval-Js([string]$expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 8
  $raw = & (Join-Path $root "cdp_call.ps1") -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram.org"
  try { $outer = $raw | ConvertFrom-Json } catch { return $null }
  return $outer.result.value
}
function Call-TgPage([hashtable]$arg) {
  if (-not $fn) { return $null }
  $json = ($arg | ConvertTo-Json -Compress -Depth 6)
  $v = Eval-Js ("(" + $fn + ")(" + $json + ")")
  if (-not $v) { return $null }
  try { return ($v | ConvertFrom-Json) } catch { return $null }
}

$fetch = {
  param($entry, $cursor)
  $key = [string]$entry.key
  $offset = [int]$cursor
  if ($key -match '^@([A-Za-z0-9_]{3,64})$') {
    $arg = @{ u = $Matches[1]; offset = $offset; limit = 200 }
  } else {
    return @{ permissionDenied = $true; error = "telegram_target_must_be_username" }
  }
  $r = Call-TgPage $arg
  if (-not $r) { return @{ error = "empty_response" } }
  if ($r.err) {
    $err = [string]$r.err
    $wait = Get-MemberRateWaitSec $err
    if ($wait -gt 0) { return @{ rateWaitSec = $wait } }
    if ($err -match 'CHANNEL_PRIVATE|CHANNEL_INVALID|CHAT_ADMIN_REQUIRED|not a member|PARTICIPANTS_TOO_FEW|AUTH_KEY|not authorized') {
      return @{ permissionDenied = $true; error = $err }
    }
    return @{ error = $err }
  }
  $users = @($r.users)
  $next = $offset + 200
  try { if ($r.nextOffset) { $next = [int]$r.nextOffset } } catch { }
  return @{
    items = $users
    done = [bool]$r.done
    next = $next
    total = [int]$r.total
    groupName = $(if ($r.peer) { [string]$r.peer.title } else { "" })
  }
}

$store = {
  param($entry, $items)
  $added = 0; $dup = 0
  $key = [string]$entry.key
  $name = [string]$entry.name
  $today = (Get-Date).ToString("yyyy/MM/dd")
  $rows = New-Object System.Collections.Generic.List[string]
  foreach ($u in @($items)) {
    $uid = [string]$u.id
    if (-not $uid) { continue }
    $k = $key + "|" + $uid
    if ($seen.ContainsKey($k)) { $dup++; continue }
    $seen[$k] = 1
    $role = if ($u.admin) { "管理员" } else { "成员" }
    $nm = [string]$u.name
    $un = [string]$u.username
    $row = [pscustomobject]@{
      platform = "Telegram"; group_key = $key; group_name = $name
      user_id = $uid; username = $un; nickname = $nm; role = $role
      collected_at = $today; source = "getParticipants"
    }
    $rows.Add(($row | ConvertTo-Json -Compress))
    $gn = ($name -replace '"', '""')
    $nm2 = ($nm -replace '"', '""')
    $csvLine = '"Telegram","' + $key + '","' + $gn + '","' + $uid + '","' + $un + '","' + $nm2 + '","","' + $role + '","","' + $today + '","getParticipants","有效"'
    [System.IO.File]::AppendAllText($csv, $csvLine + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
    $added++
  }
  if ($rows.Count -gt 0) {
    [System.IO.File]::AppendAllLines($jsonl, $rows, (New-Object System.Text.UTF8Encoding($false)))
  }
  Save-Seen
  return @{ added = $added; duplicates = $dup }
}

$result = Invoke-MemberSampleRun -BaseDir $root -Platform "telegram" -Target $Target -Trial:$Trial `
  -MaxRuntimeMin $MaxRuntimeMin -FetchPage $fetch -StorePage $store `
  -Delay { Start-Sleep -Milliseconds $PageDelayMs } `
  -StopCheck { param($b, $p) Test-MemberStopRequested $b $p } `
  -Log { param($m) Add-MemberLog $root "telegram" $m }

$line = "RESULT: " + $result.status + " target=" + $result.target + " error=" + $result.error
Write-Host $line
Add-MemberLog $root "telegram" $line
if ($result.code) { exit [int]$result.code }
exit 0
