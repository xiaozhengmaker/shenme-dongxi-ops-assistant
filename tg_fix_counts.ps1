# tg_fix_counts.ps1 -- 用 channels.getFullChannel / messages.getFullChat 的真实人数
# 回填飞书里「成员数 = 0」的 Telegram 记录（解析层拿不到 participants_count 的老 bug）。
param([int]$MinCount = 0, [switch]$IncludeHidden)

$ErrorActionPreference = "Stop"
$baseDir = Split-Path -Parent $PSCommandPath
. (Join-Path $baseDir "lib\feishu.ps1")
. (Join-Path $baseDir "lib\log.ps1")

$fn = [System.IO.File]::ReadAllText((Join-Path $baseDir "data\tg_page.js"), [System.Text.Encoding]::UTF8)
$dataDir = Join-Path $baseDir "data"

function EvalJs([string]$expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 8
  $raw = & (Join-Path $baseDir "cdp_call.ps1") -Method "Runtime.evaluate" -ParamsJson $p -Match "web.telegram.org"
  try { return ($raw | ConvertFrom-Json).result.value } catch { return $null }
}

function Val($r, $name) {
  $f = $r.fields.$name
  if ($null -eq $f) { return $null }
  if ($f -is [string]) { return $f }
  if ($f.text) { return $f.text }
  if ($f.value) { return ($f.value | ForEach-Object { if ($_.text) { $_.text } else { $_ } }) -join "" }
  return ($f | Out-String).Trim()
}

$recs = Get-FsRecords
$targets = @()
foreach ($r in $recs) {
  $plat = [string](Val $r "平台")
  if ($plat -ne "Telegram") { continue }
  $n = 0
  [void][int]::TryParse((([string](Val $r "成员数")) -replace "[^0-9]", ""), [ref]$n)
  $note = [string](Val $r "备注")
  $need = ($n -le $MinCount)
  if (-not $need -and $IncludeHidden -and $note -match "不可见") { $need = $true }
  if ($need) {
    $link = [string](Val $r "群链接")
    if ($link -match "t\.me/([A-Za-z0-9_]+)") {
      $targets += [pscustomobject]@{ id = $r.record_id; name = [string](Val $r "群名"); user = $Matches[1]; cur = $n }
    }
  }
}
Write-Log ("targets=" + $targets.Count) "INFO" "fixcount"

$updates = @()
foreach ($t in $targets) {
  $arg = @{ u = $t.user; offset = 0; limit = 1 } | ConvertTo-Json -Compress -Depth 5
  $v = EvalJs ("(" + $fn + ")(" + $arg + ")")
  if (-not $v) { Write-Log ("@" + $t.user + " no response") "WARN" "fixcount"; continue }
  $o = $v | ConvertFrom-Json
  if ($o.err) { Write-Log ("@" + $t.user + " err=" + $o.err) "WARN" "fixcount"; continue }
  $cnt = [int]$o.peer.count
  if ($cnt -le 0) { Write-Log ("@" + $t.user + " still 0") "WARN" "fixcount"; continue }
  $fields = @{ "成员数" = $cnt }
  if ($o.hidden) { $fields["备注"] = "成员名单需管理员权限(仅人数可见)" }
  elseif ($IncludeHidden -and $note -match "不可见") { $fields["备注"] = "" }
  $updates += @{ record_id = $t.id; fields = $fields }
  $suffix = ""
  if ($o.hidden) { $suffix = "  [hidden]" }
  Write-Host ("  " + $t.name + "  @" + $t.user + "  " + $t.cur + " -> " + $cnt + $suffix)
  Start-Sleep -Milliseconds 700
}

if ($updates.Count -gt 0) {
  $n = Update-FsRecords -Updates $updates
  Write-Log ("updated=" + $n) "INFO" "fixcount"
  Write-Host ("UPDATED: " + $n)
} else {
  Write-Host "UPDATED: 0"
}