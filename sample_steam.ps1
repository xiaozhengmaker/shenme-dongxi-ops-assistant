# sample_steam.ps1 -- one explicit Steam group, public memberslistxml, no joins.
param(
  [string]$Target = "",
  [switch]$Trial,
  [int]$MaxRuntimeMin = 45,
  [int]$PageDelayMs = 4000
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
. (Join-Path $root "lib\member_sample.ps1")
Clear-MemberStop $root "steam"

function Write-SampleLog([string]$m) {
  Add-MemberLog $root "steam" $m
}

$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
$csv = Join-Path $root "data\steam_users.csv"
$seen = @{}
if (Test-Path $csv) {
  try {
    foreach ($r in (Import-Csv -LiteralPath $csv -Encoding UTF8)) {
      $g = [string]$r.group_key
      $u = [string]$r.user_id
      if ($g -and $u) { $seen[$g + "|" + $u] = 1 }
    }
  } catch { }
}

$fetch = {
  param($entry, $cursor)
  $page = [int]$cursor
  if ($page -lt 1) { $page = 1 }
  $slug = [string]$entry.key
  $url = "https://steamcommunity.com/groups/$slug/memberslistxml/?xml=1&p=$page"
  $resp = $null
  try {
    $resp = Invoke-WebRequest -Uri $url -UserAgent $ua -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
  } catch {
    $code = 0
    try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
    $msg = [string]$_.Exception.Message
    if ($code -eq 401 -or $code -eq 403 -or $code -eq 404) { return @{ permissionDenied = $true; error = "http_$code" } }
    if ($code -eq 429) { return @{ rateWaitSec = [Math]::Max(300, (Get-MemberRateWaitSec $msg)) } }
    return @{ error = $(if ($code) { "http_$code" } else { "network" }) }
  }
  $txt = [string]$resp.Content
  if ($txt -match 'member list is not available|member list is private|This group is private') {
    return @{ permissionDenied = $true; error = "member_list_private" }
  }
  $totalPages = 0; $totalMembers = 0; $groupName = ""
  if ($txt -match "<totalPages>(\d+)</totalPages>") { $totalPages = [int]$Matches[1] }
  if ($txt -match "<memberCount>(\d+)</memberCount>") { $totalMembers = [int]$Matches[1] }
  if ($txt -match "<groupName><!\[CDATA\[(.*?)\]\]></groupName>") { $groupName = $Matches[1] }
  $ids = @([regex]::Matches($txt, "<steamID64>(\d+)</steamID64>") | ForEach-Object { $_.Groups[1].Value })
  $done = ($totalPages -gt 0 -and $page -ge $totalPages)
  return @{
    items = $ids
    done = $done
    next = ($page + 1)
    total = $totalMembers
    groupName = $groupName
  }
}

$store = {
  param($entry, $items)
  $added = 0; $dup = 0
  $g = [string]$entry.key
  $gn = [string]$entry.name
  if (-not (Test-Path $csv)) {
    'platform,group_key,group_name,user_id,role,collected_at,source' | Out-File -FilePath $csv -Encoding utf8
  }
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($u in @($items)) {
    $uid = [string]$u
    if (-not $uid) { continue }
    $k = $g + "|" + $uid
    if ($seen.ContainsKey($k)) { $dup++; continue }
    $seen[$k] = 1
    $lines.Add('"Steam","' + ($g -replace '"', '""') + '","' + ($gn -replace '"', '""') + '","' + $uid + '","成员","' + (Get-Date).ToString("yyyy/MM/dd") + '","memberslistxml"')
    $added++
  }
  if ($lines.Count -gt 0) {
    [System.IO.File]::AppendAllLines($csv, $lines, (New-Object System.Text.UTF8Encoding($true)))
  }
  return @{ added = $added; duplicates = $dup }
}

$result = Invoke-MemberSampleRun -BaseDir $root -Platform "steam" -Target $Target -Trial:$Trial `
  -MaxRuntimeMin $MaxRuntimeMin -FetchPage $fetch -StorePage $store `
  -Delay { Start-Sleep -Milliseconds $PageDelayMs } `
  -StopCheck { param($b, $p) Test-MemberStopRequested $b $p } `
  -Log { param($m) Add-MemberLog $root "steam" $m }

$line = "RESULT: " + $result.status + " target=" + $result.target + " error=" + $result.error
Write-Host $line
Add-MemberLog $root "steam" $line
if ($result.code) { exit [int]$result.code }
exit 0
