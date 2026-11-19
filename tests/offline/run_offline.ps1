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

foreach ($t in @("platform_cooldown.Tests.ps1", "platform_run.Tests.ps1", "pipeline_status.Tests.ps1")) {
  Write-Host ("=== " + $t + " ===")
  & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here $t)
  if ($LASTEXITCODE -ne 0) { $failed.Add($t) | Out-Null; Write-Host ("FAIL " + $t) }
}

if ($node) {
  Write-Host "=== sidepanel_actions.test.js ==="
  & node (Join-Path $here "sidepanel_actions.test.js")
  if ($LASTEXITCODE -ne 0) { $failed.Add("sidepanel_actions.test.js") | Out-Null; Write-Host "FAIL sidepanel_actions.test.js" }
}

Write-Host ""
if ($failed.Count -gt 0) { Write-Host ("OFFLINE RESULT: FAIL (" + $failed.Count + "): " + ($failed -join ", ")); exit 1 }
Write-Host "OFFLINE RESULT: PASS (all checks)"
exit 0