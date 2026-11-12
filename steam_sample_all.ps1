# steam_sample_all.ps1 -- 对飞书里所有 Steam 群各抽 N 页成员（每页 1000 个 SteamID64）
param([int]$MaxPages = 1, [int]$Limit = 0)

$baseDir = Split-Path -Parent $PSCommandPath
. (Join-Path $baseDir "lib\feishu.ps1")

$recs = Get-FsRecords
$slugs = @()
foreach ($r in $recs) {
  $plat = [string]$r.fields.'平台'
  if ($plat -ne "Steam") { continue }
  $st = [string]$r.fields.'状态'
  if ($st -eq "已退出" -or $st -eq "已失效") { continue }
  $link = [string]$r.fields.'群链接'
  if ($link -match "steamcommunity\.com/groups/([^/?#]+)") { $slugs += $Matches[1] }
}
$slugs = @($slugs | Select-Object -Unique)
if ($Limit -gt 0) { $slugs = @($slugs | Select-Object -First $Limit) }
Write-Host ("steam groups: " + $slugs.Count)

$ok = 0; $fail = @()
foreach ($g in $slugs) {
  $out = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "steam_members.ps1") -Group $g -MaxPages $MaxPages 2>&1
  $line = ($out | Select-String "WROTE:" | ForEach-Object { $_.Line }) -join " "
  if ($line) { $ok++; Write-Host ("  " + $g + " -> " + $line) } else { $fail += $g; Write-Host ("  " + $g + " -> FAIL") }
  Start-Sleep -Milliseconds 600
}
Write-Host ("DONE ok=" + $ok + " fail=" + $fail.Count + " [" + ($fail -join ",") + "]")