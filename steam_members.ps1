param(
  [string]$Group = "CounterStrike",
  [int]$MaxPages = 2,
  [int]$PageSize = 1000,
  [string]$OutDir = "D:\DeepSeek\运营\data",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
$stamp = (Get-Date).ToString("yyyy/MM/dd")

function Get-GroupXml([string]$g, [int]$page) {
  $url = "https://steamcommunity.com/groups/$g/memberslistxml/?xml=1&p=$page"
  $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 30 -Headers @{ "User-Agent" = $ua }
  if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode)" }
  if (-not $r.Content.TrimStart().StartsWith("<?xml")) { throw "非 XML 响应（群不存在或非公开）" }
  return [xml]$r.Content
}

Write-Host "FETCH page 1 for $Group ..."
$first = Get-GroupXml $Group 1
$name = $first.memberList.groupDetails.groupName.InnerText
if (-not $name) { $name = [string]$first.memberList.groupDetails.groupName }
$count = [int]$first.memberList.groupDetails.memberCount
Write-Host "GROUP: $Group | name=$name | members=$count"

$pages = [Math]::Ceiling($count / $PageSize)
$use = [Math]::Min($pages, $MaxPages)
Write-Host "PAGES: total=$pages use=$use"

$ids = New-Object System.Collections.ArrayList
$seen = @{}
for ($p = 1; $p -le $use; $p++) {
  if ($p -eq 1) { $x = $first } else {
    Start-Sleep -Milliseconds 1200
    $x = Get-GroupXml $Group $p
  }
  $nodes = $x.memberList.members.steamID64
  foreach ($n in $nodes) {
    $id = if ($n -is [string]) { $n } else { $n.InnerText }
    if ($id -and -not $seen.ContainsKey($id)) { $seen[$id] = 1; [void]$ids.Add($id) }
  }
  Write-Host "  page $p -> +$($nodes.Count) (total unique $($ids.Count))"
}

Write-Host "RESULT: group=$name collected=$($ids.Count) declared=$count"
if ($DryRun) { Write-Host "DRY RUN"; exit 0 }

$csv = Join-Path $OutDir "steam_users.csv"
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path $csv)) {
  [System.IO.File]::WriteAllText($csv, "平台,群名,群ID,SteamID64,角色,采集日,来源`r`n", $utf8bom)
}
# 同一个群重复跑时去重：先读回已有的 SteamID64
$have = @{}
if (Test-Path $csv) {
  try { foreach ($c in (Import-Csv $csv -Encoding UTF8)) { if ([string]$c."群ID" -eq $Group) { $have[[string]$c."SteamID64"] = 1 } } } catch { }
}
$sb = New-Object System.Text.StringBuilder
$newRows = 0
foreach ($id in $ids) {
  if ($have.ContainsKey($id)) { continue }
  $have[$id] = 1
  $null = $sb.AppendLine("Steam,$name,$Group,$id,成员,$stamp,群成员XML")
  $newRows++
}
$ids = @{ Count = $newRows }
[System.IO.File]::AppendAllText($csv, $sb.ToString(), $utf8)
Write-Host "WROTE: $csv newRows=$newRows (fetched=$($seen.Count))"
