# run_summary_isolation.Tests.ps1 — 状态根隔离 + 旧轮不覆盖新轮
$ErrorActionPreference = "Stop"
$baseDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $baseDir "lib\run_summary.ps1")
. (Join-Path $baseDir "lib\pipeline_status.ps1")
$fails = 0
function T([bool]$ok, [string]$name) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fails++ } }
$prodNames = @("run_summary.json", "pipeline_status.json")
$prodPath = Join-Path $baseDir "data"
$before = @{}
foreach ($n in $prodNames) { $q = Join-Path $prodPath $n; $before[$n] = if (Test-Path $q) { (Get-FileHash $q -Algorithm SHA256).Hash } else { "ABSENT" } }
$iso = Join-Path $env:TEMP ("gops_test_iso_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $iso | Out-Null
$env:GOPS_STATE_ROOT = $iso
try {
  $rid = "iso-" + (Get-Date -Format "HHmmss")
  $null = Write-RunSummary -BaseDir $baseDir -RunId $rid -StartedAt (Get-Date).AddMinutes(-2).ToString("o") -Ok $true -Code "complete" -Reason "t"
  $isoFile = Join-Path $iso "run_summary.json"
  T (Test-Path $isoFile) "iso: run_summary written to isolated root"
  T (-not (Test-Path (Join-Path $prodPath "run_summary.json")) -or ((Get-FileHash (Join-Path $prodPath "run_summary.json") -Algorithm SHA256).Hash -eq $before["run_summary.json"])) "iso: production run_summary untouched"
  $rb = Get-RunSummary -BaseDir $baseDir
  T ($rb.run_id -eq $rid -and $rb.ok -eq $true) "iso: readback run_id/ok"
  $null = Write-RunSummary -BaseDir $baseDir -RunId "newer-x" -StartedAt (Get-Date).ToString("o") -Ok $true -Code "complete" -Reason "newer"
  $null = Write-RunSummary -BaseDir $baseDir -RunId "older-x" -StartedAt (Get-Date).AddHours(-3).ToString("o") -Ok $true -Code "complete" -Reason "older"
  $r2 = Get-RunSummary -BaseDir $baseDir
  T ($r2.run_id -eq "newer-x") "guard: older write skipped (run_id=$($r2.run_id))"
  $null = Write-RunSummary -BaseDir $baseDir -RunId "forced-x" -StartedAt (Get-Date).AddHours(-3).ToString("o") -Ok $true -Code "complete" -Reason "forced" -Force
  $r3 = Get-RunSummary -BaseDir $baseDir
  T ($r3.run_id -eq "forced-x") "guard: -Force overrides"
} finally {
  Remove-Item Env:\GOPS_STATE_ROOT -ErrorAction SilentlyContinue
  Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue
}
$after = @{}
foreach ($n in $prodNames) { $q = Join-Path $prodPath $n; $after[$n] = if (Test-Path $q) { (Get-FileHash $q -Algorithm SHA256).Hash } else { "ABSENT" } }
T ($after["run_summary.json"] -eq $before["run_summary.json"]) "iso: production run_summary hash unchanged after all writes"
T ($after["pipeline_status.json"] -eq $before["pipeline_status.json"]) "iso: production pipeline_status unchanged"
if ($fails -gt 0) { "run_summary_isolation: $fails FAILED"; exit 1 }
"run_summary_isolation: all PASS"