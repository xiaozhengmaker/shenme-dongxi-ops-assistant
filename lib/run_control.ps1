# run_control.ps1 -- round/platform control signals, keyed by run ID.
# A round stop is deliberately separate from data\stop.flag (global emergency).
$script:RunControlDefault = $null

function Get-RunControlPath([string]$BaseDir) {
  if ($env:GOPS_RUN_CONTROL_FILE) { return $env:GOPS_RUN_CONTROL_FILE }
  if (-not $BaseDir) { $BaseDir = (Split-Path -Parent $PSScriptRoot) }
  return (Join-Path $BaseDir "data\run_control.json")
}

function Read-RunControl([string]$Path) {
  try {
    if (-not (Test-Path $Path)) { return $null }
    $o = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $o -or -not $o.run_id) { return $null }
    return $o
  } catch { return $null }
}

function Save-RunControl([string]$Path, $Status) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = $Path + ".tmp"
  $json = $Status | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Force $tmp $Path
}

function Register-RunControl([string]$BaseDir, [string]$RunId, [string[]]$Platforms, [string]$Current) {
  $p = Get-RunControlPath $BaseDir
  $old = Read-RunControl $p
  if ($old -and $old.run_id -ne $RunId -and $old.state -eq "running") {
    return @{ ok = $false; reason = "run_active"; run_id = [string]$old.run_id }
  }
  $now = (Get-Date).ToString("o")
  $o = [ordered]@{
    run_id = $RunId
    state = "running"
    started_at = $now
    updated_at = $now
    current_platform = [string]$Current
    platforms = @($Platforms)
    stop_requested = $false
    stop_at = ""
    skip_platform = ""
    skip_at = ""
  }
  Save-RunControl $p $o
  return @{ ok = $true; run_id = $RunId }
}

function Update-RunControlPlatform([string]$BaseDir, [string]$RunId, [string]$Current) {
  $p = Get-RunControlPath $BaseDir
  $o = Read-RunControl $p
  if (-not $o -or $o.run_id -ne $RunId) { return $false }
  $o.current_platform = [string]$Current
  $o.updated_at = (Get-Date).ToString("o")
  Save-RunControl $p $o
  return $true
}

function Request-RunStop([string]$BaseDir, [string]$RunId) {
  $p = Get-RunControlPath $BaseDir
  $o = Read-RunControl $p
  if (-not $o) { return @{ ok = $false; reason = "idle" } }
  if ($RunId -and $o.run_id -ne $RunId) { return @{ ok = $false; reason = "stale_run"; run_id = [string]$o.run_id } }
  if ($o.state -ne "running") { return @{ ok = $false; reason = "idle"; run_id = [string]$o.run_id } }
  if ($o.stop_requested) { return @{ ok = $true; already = $true; run_id = [string]$o.run_id } }
  $o.stop_requested = $true
  $o.stop_at = (Get-Date).ToString("o")
  $o.updated_at = $o.stop_at
  Save-RunControl $p $o
  return @{ ok = $true; already = $false; run_id = [string]$o.run_id }
}

function Request-PlatformSkip([string]$BaseDir, [string]$RunId, [string]$Platform) {
  $p = Get-RunControlPath $BaseDir
  $o = Read-RunControl $p
  if (-not $o) { return @{ ok = $false; reason = "idle" } }
  if ($RunId -and $o.run_id -ne $RunId) { return @{ ok = $false; reason = "stale_run"; run_id = [string]$o.run_id } }
  if ($o.state -ne "running") { return @{ ok = $false; reason = "idle"; run_id = [string]$o.run_id } }
  $cur = [string]$o.current_platform
  $want = if ($Platform) { [string]$Platform } else { $cur }
  if (-not $want) { return @{ ok = $false; reason = "platform_unknown"; run_id = [string]$o.run_id } }
  if ($cur -and $want -ne $cur) { return @{ ok = $false; reason = "stale_platform"; run_id = [string]$o.run_id; platform = $cur } }
  if ($o.skip_platform -eq $want) { return @{ ok = $true; already = $true; run_id = [string]$o.run_id; platform = $want } }
  $o.skip_platform = $want
  $o.skip_at = (Get-Date).ToString("o")
  $o.updated_at = $o.skip_at
  Save-RunControl $p $o
  return @{ ok = $true; already = $false; run_id = [string]$o.run_id; platform = $want }
}

function Test-RunStopRequested([string]$BaseDir, [string]$RunId) {
  $o = Read-RunControl (Get-RunControlPath $BaseDir)
  if (-not $o -or -not $RunId -or $o.run_id -ne $RunId) { return $false }
  return [bool]$o.stop_requested
}

function Test-RunPlatformSkip([string]$BaseDir, [string]$RunId, [string]$Platform) {
  $o = Read-RunControl (Get-RunControlPath $BaseDir)
  if (-not $o -or -not $RunId -or $o.run_id -ne $RunId) { return $false }
  return ($o.skip_platform -and $o.skip_platform -eq [string]$Platform)
}

function Complete-RunControl([string]$BaseDir, [string]$RunId) {
  $p = Get-RunControlPath $BaseDir
  $o = Read-RunControl $p
  if (-not $o -or $o.run_id -ne $RunId) { return }
  $o.state = "complete"
  $o.skip_platform = ""
  $o.updated_at = (Get-Date).ToString("o")
  Save-RunControl $p $o
}

function Close-RunControl([string]$BaseDir, [string]$RunId, [string]$State = "stopped") {
  $p = Get-RunControlPath $BaseDir
  $o = Read-RunControl $p
  if (-not $o -or $o.run_id -ne $RunId) { return }
  $o.state = $State
  $o.skip_platform = ""
  $o.updated_at = (Get-Date).ToString("o")
  Save-RunControl $p $o
}

function Get-RunControlView([string]$BaseDir) {
  $o = Read-RunControl (Get-RunControlPath $BaseDir)
  if (-not $o) { return $null }
  return $o
}

function Wait-RunSignal([string]$BaseDir, [string]$RunId, [string]$Platform, [int]$Seconds = 600, [int]$SleepMs = 1000) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-GOpsStop $BaseDir) { return "stop" }
    if (Test-RunStopRequested -BaseDir $BaseDir -RunId $RunId) { return "stop" }
    if ($Platform -and (Test-RunPlatformSkip -BaseDir $BaseDir -RunId $RunId -Platform $Platform)) { return "skip" }
    Start-Sleep -Milliseconds $SleepMs
  }
  return "timeout"
}

function Test-WorkerStop([string]$BaseDir) {
  if (Test-GOpsStop $BaseDir) { return $true }
  $rid = [string]$env:GOPS_RUN_ID
  if ($rid -and (Test-RunStopRequested -BaseDir $BaseDir -RunId $rid)) { return $true }
  $plat = [string]$env:GOPS_PLATFORM
  if ($rid -and $plat -and (Test-RunPlatformSkip -BaseDir $BaseDir -RunId $rid -Platform $plat)) { return $true }
  return $false
}
