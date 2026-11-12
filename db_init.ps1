# 初始化本地数据库（建表 + 索引），可重复执行
$baseDir = $PSScriptRoot
. (Join-Path $baseDir "lib\db.ps1")
$r = Initialize-LocalDb
Write-Host ("DB: " + $r.path)
Write-Host ("OK: " + $r.ok)
