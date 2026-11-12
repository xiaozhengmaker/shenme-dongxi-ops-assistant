param(
  [Parameter(Mandatory=$true)][string]$GroupId,
  [string]$GroupName = '',
  [int]$Max = 800,
  [int]$SpacingMinMs = 2500,
  [int]$SpacingMaxMs = 4000,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$csv = Join-Path $dataDir 'users.csv'
$jsonl = Join-Path $dataDir 'users.jsonl'
$extract = [System.IO.File]::ReadAllText((Join-Path $dataDir 'fb_extract.js'), [System.Text.Encoding]::UTF8)

function CdpEval([string]$expr) {
  $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } | ConvertTo-Json -Compress -Depth 6
  $raw = & (Join-Path $root 'cdp_call.ps1') -Method 'Runtime.evaluate' -ParamsJson $p -Match 'facebook.com'
  $obj = $raw | ConvertFrom-Json
  return $obj.result.result.value
}

$url = "https://www.facebook.com/groups/$GroupId/members"
$np = @{ url = $url } | ConvertTo-Json -Compress
& (Join-Path $root 'cdp_call.ps1') -Method 'Page.navigate' -ParamsJson $np -Match 'facebook.com' | Out-Null
Start-Sleep -Seconds 6

if (-not (Test-Path $csv)) {
  '平台,群ID,群名,用户ID,用户名,昵称,语言,角色,最近活跃,采集日,来源,状态' | Out-File -FilePath $csv -Encoding utf8
}

$seen = @{}
$collected = 0
if (Test-Path $jsonl) {
  foreach ($line in (Get-Content $jsonl -Encoding UTF8)) {
    if (-not $line) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.group -eq $GroupId) { $seen[$o.user_id] = 1; $collected++ }
  }
}
"already collected for this group: $collected"

$round = 0
$emptyRounds = 0
$today = (Get-Date).ToString('yyyy/MM/dd')
while ($collected -lt $Max -and $round -lt 120) {
  $round++
  $r = CdpEval $extract
  if ($r.warn) { "!! 页面出现验证/限制提示，停止。href=$($r.href)"; break }
  $items = $r.items
  $added = 0
  foreach ($it in $items) {
    $k = [string]$it.k
    if (-not $k -or $seen.ContainsKey($k)) { continue }
    $seen[$k] = 1
    $row = [pscustomobject]@{
      platform = 'Facebook'; group = $GroupId; groupname = $GroupName
      user_id = $k; username = ''; nickname = [string]$it.name; lang = ''
      role = ''; last_active = $null; collected_at = $today
      source = '成员页'; status = '有效'
    }
    ($row | ConvertTo-Json -Compress) | Out-File -FilePath $jsonl -Encoding utf8 -Append
    $nm = ([string]$it.name) -replace '"', '""'
    $gn = ($GroupName -replace '"', '""')
    $line = '"Facebook","' + $GroupId + '","' + $gn + '","' + $k + '","","' + $nm + '","","","","' + $today + '","成员页","有效"'
    $line | Out-File -FilePath $csv -Encoding utf8 -Append
    $collected++
    $added++
    if ($collected -ge $Max) { break }
  }
  "round $round : DOM=$($r.n) added=$added collected=$collected"
  if ($added -eq 0) { $emptyRounds++ } else { $emptyRounds = 0 }
  if ($emptyRounds -ge 4) { 'no new items after 4 rounds, stop'; break }
  if ($DryRun) { break }
  CdpEval "window.scrollBy(0, 900); 'ok'" | Out-Null
  $wait = Get-Random -Minimum $SpacingMinMs -Maximum $SpacingMaxMs
  Start-Sleep -Milliseconds $wait
}
@{ group = $GroupId; collected = $collected; rounds = $round; at = (Get-Date).ToString('s') } | ConvertTo-Json | Out-File -FilePath (Join-Path $dataDir ("cursor_fb_$GroupId.json")) -Encoding utf8
"done collected=$collected rounds=$round"