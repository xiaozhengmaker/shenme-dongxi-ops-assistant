function Invoke-LiveSuite {
  $live = Join-Path $PSScriptRoot "..\live\round_integration.ps1"
  if (-not (Test-Path $live)) { Write-Host "[live] missing"; return $true }
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $live 2>&1 | Out-String
  $ok = ($o -match "fail=0")
  Write-Host ("[live] round_integration -> " + $(if ($ok) { "PASS" } else { "FAIL" }))
  if (-not $ok) { Write-Host ($o -split "`r?`n" | Select-Object -Last 3 | Out-String) }
  return $ok
}
# run_offline.ps1 -- offline checks for the increments ported into this repo.
# No network, no browser, no project writes.
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)
$failed = New-Object System.Collections.ArrayList

Write-Host "=== syntax: PowerShell ==="
Get-ChildItem -Recurse -File $root -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\_backup\\|\\dist\\' } | ForEach-Object {
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) {
    $failed.Add("syntax " + $_.Name) | Out-Null
    Write-Host ("FAIL syntax " + $_.Name)
    $errs | Select-Object -First 3 | ForEach-Object { Write-Host ("  line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
  } else { Write-Host ("PASS syntax " + $_.Name) }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  Write-Host "=== syntax: JS ==="
  foreach ($f in @("extension\src\background.js", "extension\src\sidepanel.js")) {
    & node --check (Join-Path $root $f)
    if ($LASTEXITCODE -ne 0) { $failed.Add("syntax " + $f) | Out-Null; Write-Host ("FAIL syntax " + $f) } else { Write-Host ("PASS syntax " + $f) }
  }
} else { Write-Host "SKIP node (not available)" }

foreach ($t in @("platform_cooldown.Tests.ps1", "platform_run.Tests.ps1", "pipeline_status.Tests.ps1", "run_summary_isolation.Tests.ps1", "join_dedup.Tests.ps1", "run_plan.Tests.ps1", "plan_gate.Tests.ps1", "hub_dispatch.Tests.ps1", "round_report.Tests.ps1")) {
  Write-Host ("=== " + $t + " ===")
  & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here $t)
  if ($LASTEXITCODE -ne 0) { $failed.Add($t) | Out-Null; Write-Host ("FAIL " + $t) }
}

if ($node) {
  foreach ($js in @("sidepanel_actions.test.js", "fb_join_fixtures.test.js", "ui_start_payload.test.js", "sidepanel_states.test.js")) {
    Write-Host ("=== " + $js + " ===")
    & node (Join-Path $here $js)
    if ($LASTEXITCODE -ne 0) { $failed.Add($js) | Out-Null; Write-Host ("FAIL " + $js) }
  }
}

Write-Host ""
if ($failed.Count -gt 0) { Write-Host ("OFFLINE RESULT: FAIL (" + $failed.Count + "): " + ($failed -join ", ")); exit 1 }
Write-Host "OFFLINE RESULT: PASS (all checks)"
exit 0