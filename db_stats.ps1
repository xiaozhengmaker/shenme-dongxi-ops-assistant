# 查看本地数据库概况
$baseDir = $PSScriptRoot
. (Join-Path $baseDir "lib\db.ps1")
$r = Get-DbStats
if (-not $r.ok) { Write-Host ("DB not ready: " + $r.path); exit 0 }
Write-Host ("PATH : " + $r.path)
Write-Host ("ROWS : " + $r.rows)
Write-Host ("GROUPS: " + $r.groups)
Write-Host ("SIZE : " + $r.size_mb + " MB")
foreach ($p in $r.platforms) { Write-Host ("  " + $p.name + " " + $p.users + " users / " + $p.groups + " groups") }
