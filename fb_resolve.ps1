param(
  [int]$Limit = 0,
  [switch]$NoFeishu
)
$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
$dataDir = Join-Path $rootDir "data"
. (Join-Path $rootDir "lib\feishu.ps1")
$liteJs = [System.IO.File]::ReadAllText((Join-Path $dataDir "fb_lite.js"), [System.Text.Encoding]::UTF8)
$searchJs = [System.IO.File]::ReadAllText((Join-Path $dataDir "fb_search.js"), [System.Text.Encoding]::UTF8)
$today = (Get-Date).ToString("yyyy/MM/dd")
$csv = Join-Path $dataDir "users.csv"
$jsonl = Join-Path $dataDir "users.jsonl"

function Cdp([string]$method, [string]$paramsJson) {
  return (& (Join-Path $rootDir "cdp_call.ps1") -Method $method -ParamsJson $paramsJson -Match "facebook.com" | Out-String)
}
function Navigate([string]$url) {
  $p = @{ url = $url } | ConvertTo-Json -Compress
  Cdp "Page.navigate" $p | Out-Null
  Start-Sleep -Seconds 6
}
function JsVal([string]$expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 8
  $raw = Cdp "Runtime.evaluate" $p
  try { $o = $raw | ConvertFrom-Json } catch { return $null }
  return $o.result.value
}
function CurrentGroupId {
  $v = JsVal "location.href"
  if ($v -match "groups/(\d+)") { return $Matches[1] }
  return ""
}

$recs = Get-FsRecords
$fb = $recs | Where-Object { $_.fields.'平台' -eq "Facebook" }
if ($Limit -gt 0) { $fb = $fb | Select-Object -First $Limit }
"fb rows: $($fb.Count)"
$updates = @()
$i = 0
foreach ($r in $fb) {
  $i++
  $name = [string]$r.fields.'群名'
  $link = [string]$r.fields.'群链接'
  $gid = ""
  if ($link -match "groups/(\d+)") { $gid = $Matches[1] }
  elseif ($link -match "groups/([A-Za-z0-9._-]+)") {
    $slug = $Matches[1]
    Navigate "https://m.facebook.com/groups/$slug/members/"
    $gid = CurrentGroupId
    "[$i] slug=$slug -> id=$gid"
  }
  if (-not $gid) {
    $q = [uri]::EscapeDataString($name)
    Navigate "https://www.facebook.com/search/groups/?q=$q"
    $rawv = JsVal $searchJs
    $cands = @()
    if ($rawv -is [string] -and $rawv.TrimStart().StartsWith("{")) {
      $d = $rawv | ConvertFrom-Json
      $cands = $d.items
    }
    $norm = { param($s) (($s -replace "[^\p{L}\p{N}]", "")).ToLower() }
    $toks = { param($s) @(($s.ToLower() -replace "[^\p{L}\p{N}\s]", " ") -split "\s+" | Where-Object { $_.Length -ge 2 }) }
    $tgt = & $norm $name
    $tt = & $toks $name
    $best = $null
    $bestScore = 0.0
    foreach ($c in $cands) {
      $cn = & $norm ([string]$c.name)
      if ($cn -eq $tgt) { $best = $c; $bestScore = 1.0; break }
      if ($tgt.Length -ge 6 -and ($cn.Contains($tgt) -or $tgt.Contains($cn))) { $best = $c; $bestScore = 0.9; continue }
      $ct = & $toks ([string]$c.name)
      if ($tt.Count -eq 0) { continue }
      $hit = 0
      foreach ($x in $tt) { if ($ct -contains $x) { $hit++ } }
      $score = [double]$hit / [double]$tt.Count
      if ($score -gt $bestScore -and $score -ge 0.6) { $best = $c; $bestScore = $score }
    }
    if ($best) { $gid = [string]$best.id }
    "[$i] search=$name -> cands=$($cands.Count) id=$gid"
  }
  if (-not $gid) { "[$i] SKIP $name (no id)"; continue }
  $np = @{ url = "https://m.facebook.com/groups/$gid/members/" } | ConvertTo-Json -Compress
  Cdp "Page.navigate" $np | Out-Null
  Start-Sleep -Seconds 6
  $key = "fb-" + $gid
  $seen = @{}
  $col = 0
  if (Test-Path $jsonl) {
    foreach ($line in (Get-Content $jsonl -Encoding UTF8)) {
      if (-not $line) { continue }
      try { $o = $line | ConvertFrom-Json } catch { continue }
      if ($o.group_key -eq $key) { $seen[[string]$o.user_id] = 1; $col++ }
    }
  }
  $rawv = JsVal $liteJs
  $data = $null
  if ($rawv -is [string] -and $rawv.TrimStart().StartsWith("{")) { $data = $rawv | ConvertFrom-Json }
  if (-not $data) { "[$i] $gid empty"; continue }
  if ($data.warn) { "[$i] $gid WARN 验证"; continue }
  $added = 0
  foreach ($it in $data.items) {
    $uid = [string]$it.k
    if (-not $uid -or $seen.ContainsKey($uid)) { continue }
    $seen[$uid] = 1
    $row = [pscustomobject]@{
      platform = "Facebook"; group_key = $key; group_id = $gid; group_name = $name
      user_id = $uid; username = ""; nickname = [string]$it.name; lang = ""
      role = [string]$it.role; last_active = $null; collected_at = $today; source = "成员页"; status = "有效"
    }
    ($row | ConvertTo-Json -Compress) | Out-File -FilePath $jsonl -Encoding utf8 -Append
    $nm = ([string]$it.name) -replace '"', '""'
    $gn = ($name -replace '"', '""')
    ('"Facebook","' + $key + '","' + $gid + '","' + $gn + '","' + $uid + '","","' + $nm + '","","' + [string]$it.role + '","","' + $today + '","成员页","有效"') | Out-File -FilePath $csv -Encoding utf8 -Append
    $added++; $col++
  }
  "[$i] $gid $name added=$added total=$col"
  if (-not $NoFeishu) {
    $updates += @{ record_id = $r.record_id; fields = @{ "群链接" = "https://www.facebook.com/groups/$gid"; "群ID" = $gid } }
  }
  Start-Sleep -Milliseconds 1200
}
if ($updates.Count -gt 0) {
  $n = Update-FsRecords -Updates $updates
  "feishu updated: $n"
}
"done rows=$($fb.Count) updates=$($updates.Count)"