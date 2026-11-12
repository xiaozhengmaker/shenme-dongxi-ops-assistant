param([switch]$DryRun)

$ErrorActionPreference = "Continue"
$here = $PSScriptRoot
$log = Join-Path $here "logs\report_all.log"
function Log($m) {
  $line = (Get-Date).ToString("yyyy/MM/dd HH:mm:ss") + " " + $m
  Write-Host $line
  $dir = Split-Path $log -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  Add-Content -Path $log -Value $line -Encoding UTF8
}

Log "=== report_all start ==="

$r1 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "report.ps1") @(if ($DryRun) { "-DryRun" })
Log ("groups report: " + (($r1 | Select-Object -Last 1) -join " "))
Start-Sleep -Seconds 2

$r2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "report_users.ps1") @(if ($DryRun) { "-DryRun" })
Log ("users report: " + (($r2 | Select-Object -Last 1) -join " "))

Log "=== report_all done ==="
