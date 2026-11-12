param(
  [Parameter(Mandatory=$true)][string]$GroupId,
  [string]$GroupName = "",
  [int]$Max = 400,
  [int]$Scrolls = 20,
  [int]$SpacingMinMs = 2200,
  [int]$SpacingMaxMs = 3800,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
$dataDir = Join-Path $rootDir "data"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$csv = Join-Path $dataDir "users.csv"
$jsonl = Join-Path $dataDir "users.jsonl"
$fn = [System.IO.File]::ReadAllText((Join-Path $dataDir "fb_interact.js"), [System.Text.Encoding]::UTF8)
$today = (Get-Date).ToString("yyyy/MM/dd")
$key = "fb-" + $GroupId
if (-not (Test-Path $csv)) {
  '平台,群ID,群名,用户ID,用户名,昵称,语言,角色,最近活跃,采集日,来源,状态' | Out-File -FilePath $csv -Encoding utf8
}
function CallJs([string]$expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 8
  $raw = & (Join-Path $rootDir "cdp_call.ps1") -Method "Runtime.evaluate" -ParamsJson $p -Match "facebook.com"
  $o = $raw | ConvertFrom-Json
  $v = $o.result.value
  if (-not $v) { return $null }
  if ($v -isnot [string]) { return $v }
  if (-not $v.TrimStart().StartsWith("{")) { return $null }
  try { return ($v | ConvertFrom-Json) } catch { return $null }
}
$url = "https://m.facebook.com/groups/$GroupId/"
$np = @{ url = $url } | ConvertTo-Json -Compress
& (Join-Path $rootDir "cdp_call.ps1") -Method "Page.navigate" -ParamsJson $np -Match "facebook.com" | Out-Null
Start-Sleep -Seconds 8
CallJs "window.scrollBy(0, 900)" | Out-Null
Start-Sleep -Milliseconds 2500
CallJs "window.scrollBy(0, 900)" | Out-Null
Start-Sleep -Milliseconds 2500
$seen = @{}
$collected = 0
if (Test-Path $jsonl) {
  foreach ($line in (Get-Content $jsonl -Encoding UTF8)) {
    if (-not $line) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.group_key -eq $key) { $seen[[string]$o.user_id] = 1; $collected++ }
  }
}
"resume key=$key already=$collected"
for ($s = 1; $s -le $Scrolls; $s++) {
  $expr = $fn
  $r = CallJs $expr
  if (-not $r) { "!! empty"; break }
  if ($r.warn) { "!! 验证/限制提示，停止"; break }
  $added = 0
  foreach ($it in $r.items) {
    $uid = [string]$it.k
    if (-not $uid -or $seen.ContainsKey($uid)) { continue }
    $seen[$uid] = 1
    $row = [pscustomobject]@{
      platform = "Facebook"; group_key = $key; group_id = $GroupId; group_name = $GroupName
      user_id = $uid; username = ""; nickname = [string]$it.name; lang = ""
      role = [string]$it.role; last_active = $null; collected_at = $today; source = "帖子互动"; status = "有效"
    }
    ($row | ConvertTo-Json -Compress) | Out-File -FilePath $jsonl -Encoding utf8 -Append
    $nm = ([string]$it.name) -replace '"', '""'
    $gn = ($GroupName -replace '"', '""')
    ('"Facebook","' + $key + '","' + $GroupId + '","' + $gn + '","' + $uid + '","","' + $nm + '","","' + [string]$it.role + '","","' + $today + '","帖子互动","有效"') | Out-File -FilePath $csv -Encoding utf8 -Append
    $collected++
    $added++
    if ($collected -ge $Max) { break }
  }
  "scroll $s posts=$($r.posts) dom=$($r.n) added=$added total=$collected"
  if ($collected -ge $Max) { "cap reached"; break }
  if ($DryRun) { break }
  CallJs "window.scrollBy(0, 1200)" | Out-Null
  Start-Sleep -Milliseconds (Get-Random -Minimum $SpacingMinMs -Maximum $SpacingMaxMs)
}
"done collected=$collected"