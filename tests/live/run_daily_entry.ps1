param(
  [string]$Root = ""
)
$ErrorActionPreference = "Stop"
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$rd = Join-Path $Root "run_daily.ps1"
if (-not (Test-Path $rd)) { Write-Host "  FAIL run_daily.ps1 missing"; exit 2 }
$sha = (Get-FileHash -LiteralPath $rd -Algorithm SHA256).Hash.Substring(0, 16)
Write-Host ("[entry] executing deployed " + $rd + " sha16=" + $sha)
$work = Join-Path $env:TEMP ("gops_daily_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:GOPS_PLANNED_ROUND = "1"
$env:GOPS_ROUND_WORKDIR = $work
$env:GOPS_ROUND_RUNNERS = (Join-Path $Root "tests\live\fake_runners.ps1")
$env:GOPS_ROUND_PLAN = "Telegram,Steam"
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rd 2>&1 | Out-String
$code = $LASTEXITCODE
Remove-Item Env:\GOPS_PLANNED_ROUND, Env:\GOPS_ROUND_RUNNERS, Env:\GOPS_ROUND_PLAN, Env:\GOPS_ROUND_WORKDIR -ErrorAction SilentlyContinue
$line = (($out -split "`r?`n") | Where-Object { $_ -match "\[round\]" } | Select-Object -First 1)
Write-Host ("[entry] " + $line.Trim() + " exit=" + $code)
$fails = New-Object System.Collections.ArrayList
function Assert-That([bool]$cond, [string]$name, [string]$detail = "") {
  if ($cond) { Write-Host ("  PASS " + $name) } else { Write-Host ("  FAIL " + $name + " :: " + $detail); $null = $fails.Add($name) }
}
Assert-That ($code -eq 0) "entry: exit 0" ("exit=" + $code)
Assert-That ($line -match "state=complete") "entry: state=complete" $line
Assert-That ($line -match "joined=2") "entry: joined=2" $line
Assert-That ($line -match "pending=0") "entry: pending=0" $line
$rcPath = Join-Path $work "data\run_control.json"
$suPath = Join-Path $work "data\run_summary.json"
Assert-That (Test-Path $rcPath) "entry: run_control written"
Assert-That (Test-Path $suPath) "entry: run_summary written"
if (Test-Path $rcPath) {
  $rc = Get-Content $rcPath -Raw | ConvertFrom-Json
  $su = Get-Content $suPath -Raw | ConvertFrom-Json
  Assert-That ([string]$rc.entry -eq "daily") "entry: entry=daily" ([string]$rc.entry)
  Assert-That ([string]$rc.run_id -like "run_daily-*") "entry: run_id persisted" ([string]$rc.run_id)
  Assert-That ([string]$rc.run_id -eq [string]$su.run_id) "entry: same run_id in summary" ([string]$rc.run_id + " vs " + [string]$su.run_id)
  Assert-That ([int]$su.summary.joined -eq 2) "entry: summary joined=2" ([string]$su.summary.joined)
  Write-Host ("[entry] run_id=" + $rc.run_id + " state=" + $rc.state)
}
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
if ($fails.Count -gt 0) { Write-Host ("RESULT fail=" + $fails.Count); exit 1 }
Write-Host "RESULT pass=10 fail=0"
exit 0
