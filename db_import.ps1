# 把 data\users.csv 导入本地数据库（幂等 upsert）
param([string[]]$Csv = @())
$baseDir = $PSScriptRoot
. (Join-Path $baseDir "lib\db.ps1")
if (-not $Csv -or $Csv.Count -eq 0) { $Csv = @((Join-Path $baseDir "data\users.csv")) }
$r = Import-LocalDb -CsvPaths $Csv
Write-Host ("IMPORTED: " + $r.imported)
foreach ($f in $r.files) { Write-Host ("  " + $f.file + " -> " + $f.rows + " rows, skipped " + $f.skipped) }
