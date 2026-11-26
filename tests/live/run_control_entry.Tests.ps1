# run_control_entry.Tests.ps1 -- safe entry-point tests for the two orchestrators.
# Uses a disposable copy and a pre-set stop flag so neither entry can touch the
# real hub, real config, or any business platform.
param([string]$SourceDir = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$ErrorActionPreference = "Stop"
$pass = 0
$fail = 0
function T([string]$name, [scriptblock]$fn) {
  try { & $fn; Write-Host ("PASS  " + $name); $script:pass++ }
  catch { Write-Host ("FAIL  " + $name + " :: " + $_.Exception.Message); $script:fail++ }
}
function A($cond, [string]$msg) { if (-not $cond) { throw $msg } }

$old = @{}
foreach ($k in @("GOPS_STATE_ROOT", "GOPS_RUN_CONTROL_FILE", "GOPS_STOP_FILE", "GOPS_OFFLINE")) { $old[$k] = [Environment]::GetEnvironmentVariable($k) }
$temps = New-Object System.Collections.ArrayList
function New-Sandbox {
  $t = Join-Path $env:TEMP ("gops-entry-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $t -Force | Out-Null
  foreach ($file in @("hub.ps1","run_all.ps1","run_daily.ps1","config.example.json","lib","extension")) { Copy-Item -LiteralPath (Join-Path $SourceDir $file) -Destination $t -Recurse }
  Copy-Item -LiteralPath (Join-Path $t "config.example.json") -Destination (Join-Path $t "config.json") -Force
  New-Item -ItemType Directory -Path (Join-Path $t "logs"), (Join-Path $t "data"), (Join-Path $t "state") -Force | Out-Null
  $env:GOPS_STATE_ROOT = Join-Path $t "state"
  $env:GOPS_RUN_CONTROL_FILE = Join-Path $t "state\run_control.json"
  $env:GOPS_STOP_FILE = Join-Path $t "state\stop.flag"
  $env:GOPS_OFFLINE = "1"
  Set-Content -LiteralPath $env:GOPS_STOP_FILE -Value "test-stop" -Encoding ASCII
  [void]$temps.Add($t)
  return $t
}
try {
  T "daily-startup-stop-pipeline-shape" {
    $t = New-Sandbox
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $t "run_daily.ps1") *> (Join-Path $t "daily.out")
    A ($LASTEXITCODE -eq 0) ("exit=" + $LASTEXITCODE)
    $p = Get-Content (Join-Path $t "state\pipeline_status.json") -Raw | ConvertFrom-Json
    A ($p.state -eq "stopped") ("state=" + $p.state)
    A (@($p.platforms) -notcontains "hub") ("platforms=" + (@($p.platforms) -join ","))
    A (@($p.phases) -contains "hub") ("phases=" + (@($p.phases) -join ","))
    A (@($p.phases) -contains "Steam") ("phases=" + (@($p.phases) -join ","))
  }

  T "run-all-stop-closes-pipeline" {
    $t = New-Sandbox
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $t "run_all.ps1") -SkipSelfCheck -SkipMembers -SkipSteam -SkipLeads -NoReport -HubUrl "http://127.0.0.1:9" *> (Join-Path $t "all.out")
    A ($LASTEXITCODE -eq 0) ("exit=" + $LASTEXITCODE)
    $p = Get-Content (Join-Path $t "state\pipeline_status.json") -Raw | ConvertFrom-Json
    A ($p.state -eq "stopped") ("state=" + $p.state)
    A ([string]$p.run_id -like "run_all-*") ("run_id=" + $p.run_id)
  }
} finally {
  foreach ($k in $old.Keys) {
    if ($null -eq $old[$k]) { Remove-Item ("env:" + $k) -ErrorAction SilentlyContinue }
    else { Set-Item ("env:" + $k) $old[$k] }
  }
  foreach ($t in $temps) { if ([IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $t).Path) -eq (Resolve-Path -LiteralPath $env:TEMP).Path -and [IO.Path]::GetFileName($t) -match "^gops-entry-[0-9a-f]{32}$") { Remove-Item -LiteralPath $t -Recurse -Force } }
}
Write-Host ("RESULT pass=" + $pass + " fail=" + $fail)
if ($fail -gt 0) { exit 1 }
