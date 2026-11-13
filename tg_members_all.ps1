param(
  [int]$MaxPerGroup = 1000,
  [int]$Limit = 0,
  [int]$GroupSpacingMinMs = 1200,
  [int]$GroupSpacingMaxMs = 2600
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$rootDir = $PSScriptRoot
. (Join-Path $rootDir "lib\feishu.ps1")
$recs = Get-FsRecords
$tg = $recs | Where-Object { $_.fields.'平台' -eq "Telegram" } | ForEach-Object {
  $n = [string]$_.fields.'群名'
  $l = [string]$_.fields.'群链接'
  if ($l -match "t\.me/([A-Za-z0-9_]{4,})") { [pscustomobject]@{ key = "@" + $Matches[1].ToLower(); name = $n } }
} | Sort-Object key -Unique
if ($Limit -gt 0) { $tg = $tg | Select-Object -First $Limit }
"tg groups with username: $($tg.Count)"
$i = 0
$report = @()
foreach ($g in $tg) {
  if (Test-GOpsStop $baseDir) { "[stop] flag found, exit"; exit 0 }
  $i++
  $u = $g.key.TrimStart("@")
  "[$i/$($tg.Count)] $u ..."
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rootDir "tg_members.ps1") -Username $u -Max $MaxPerGroup 2>&1 | Out-String
  $line = ($out -split "`n" | Where-Object { $_ -match "^done collected=" }) -join ""
  if (-not $line) {
    $sk = ($out -split "`n" | Where-Object { $_ -match "^SKIP " }) -join ""
    if ($sk) { $line = $sk }
    else {
      $rs = ($out -split "`n" | Where-Object { $_ -match "^RESULT: " }) -join ""
      if ($rs) { $line = $rs }
    }
  }
  $peerLine = ($out -split "`n" | Where-Object { $_ -match "^peer:" }) -join ""
  "   $peerLine | $line"
  $report += [pscustomobject]@{ username = $u; peer = $peerLine; result = $line }
  Start-Sleep -Milliseconds (Get-Random -Minimum $GroupSpacingMinMs -Maximum $GroupSpacingMaxMs)
}
$report | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $rootDir "data\batch_report.json") -Encoding utf8
"batch done. groups=$($tg.Count)"