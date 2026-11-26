# run_control.ps1 -- round/platform control signals, keyed by run ID.
# A round stop is deliberately separate from data\stop.flag (global emergency).
$script:RunControlDefault = $null

function Get-RunControlPath([string]$BaseDir) {
  if ($env:GOPS_RUN_CONTROL_FILE) { return $env:GOPS_RUN_CONTROL_FILE }
  if ($env:GOPS_STATE_ROOT) { return (Join-Path $env:GOPS_STATE_ROOT "run_control.json") }
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

function Set-RunControlField {
  # Durable records written by older builds (or by a recovery test) may not
  # carry every optional field. Add it before assigning instead of throwing
  # inside a close/stop path, which would leave a dead round "running".
  param($Object, [string]$Name, $Value)
  if ($null -eq $Object) { return }
  if ($Object -is [System.Collections.IDictionary]) {
    $Object[$Name] = $Value
    return
  }
  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
    return
  }
  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Save-RunControl([string]$Path, $Status) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = $Path + ".tmp"
  $json = $Status | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Force $tmp $Path
}

function Lock-RunControl([string]$Path) {
  $lockPath = $Path + ".lock"
  $deadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $deadline) {
    try {
      return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch {
      try {
        if ((Get-Item $lockPath -ErrorAction Stop).LastWriteTime -lt (Get-Date).AddSeconds(-30)) { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue }
      } catch { }
      Start-Sleep -Milliseconds 50
    }
  }
  return $null
}

function Unlock-RunControl($Lock, [string]$Path) {
  try { if ($Lock) { $Lock.Dispose() } } catch { }
  try { Remove-Item -LiteralPath ($Path + ".lock") -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-RunOwnerProcessId([string]$RunId) {
  if (-not $RunId) { return 0 }
  if ($RunId -match '^(?:run_all|run_daily)-\d{8}-\d{6}-(\d+)$') { return [int]$Matches[1] }
  return 0
}

function Test-RunControlOwnerAlive {
  # Unknown owners (legacy hub-* records without owner_pid) are treated as alive:
  # never reclaim a round merely because its owner cannot be identified.
  param($Status, [string]$RunId = "", [string]$BaseDir = "")
  $ownerPid = 0
  try { if ($Status -and $Status.owner_pid) { $ownerPid = [int]$Status.owner_pid } } catch { }
  if ($ownerPid -le 0) { $ownerPid = Get-RunOwnerProcessId $RunId }
  if ($ownerPid -le 0) { return $true }
  try {
    $proc = Get-Process -Id $ownerPid -ErrorAction Stop
    if (-not $proc -or $proc.HasExited) { return $false }
    $started = $null
    if ($Status -and $Status.started_at) { try { $started = [datetime]::Parse([string]$Status.started_at) } catch { } }
    if (-not $started -and $RunId -match '^(?:run_all|run_daily)-(\d{8})-(\d{6})-\d+$') {
      try { $started = [datetime]::ParseExact(($Matches[1] + $Matches[2]), 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    # Guard against PID reuse: a different process that started well after this
    # run was registered cannot be its owner.
    if ($started -and $proc.StartTime -gt $started.AddMinutes(5)) { return $false }
    return $true
  } catch { return $false }
}

function Register-RunControl([string]$BaseDir, [string]$RunId, [string[]]$Platforms, [string]$Current, [int]$OwnerPid = 0, [string]$OwnerKind = "") {
  $p = Get-RunControlPath $BaseDir
  $dir = Split-Path -Parent $p
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  # Best-effort short lock so two orchestrators cannot both pass the ownership
  # check and overwrite each other. The post-save re-read is the authoritative
  # race check.
  $lock = Lock-RunControl $p
  if (-not $lock) { return @{ ok = $false; reason = "run_control_busy"; run_id = "" } }
  try {
    $old = Read-RunControl $p
    if ($old -and $old.run_id -ne $RunId -and $old.state -eq "running") {
      if (Test-RunControlOwnerAlive -Status $old -RunId ([string]$old.run_id)) {
        return @{ ok = $false; reason = "run_active"; run_id = [string]$old.run_id }
      }
      try {
        $stale = $p + ".stale." + (Get-Date).ToString("yyyyMMdd-HHmmss") + ".json"
        Copy-Item -LiteralPath $p -Destination $stale -Force
      } catch { }
    }
    $now = (Get-Date).ToString("o")
    $pidToStore = if ($OwnerPid -gt 0) { $OwnerPid } else { Get-RunOwnerProcessId $RunId }
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
      owner_pid = [int]$pidToStore
      owner_kind = [string]$OwnerKind
    }
    Save-RunControl $p $o
    $check = Read-RunControl $p
    if (-not $check -or [string]$check.run_id -ne $RunId) {
      return @{ ok = $false; reason = "run_active"; run_id = $(if ($check) { [string]$check.run_id } else { "" }) }
    }
    return @{ ok = $true; run_id = $RunId }
  } finally {
    Unlock-RunControl $lock $p
  }
}

function Update-RunControlPlatform([string]$BaseDir, [string]$RunId, [string]$Current) {
  $p = Get-RunControlPath $BaseDir
  $lock = Lock-RunControl $p
  if (-not $lock) { return $false }
  try {
    $o = Read-RunControl $p
    if (-not $o -or $o.run_id -ne $RunId) { return $false }
    Set-RunControlField $o "current_platform" ([string]$Current)
    Set-RunControlField $o "updated_at" ((Get-Date).ToString("o"))
    Save-RunControl $p $o
    return $true
  } finally { Unlock-RunControl $lock $p }
}

function Request-RunStop([string]$BaseDir, [string]$RunId) {
  $p = Get-RunControlPath $BaseDir
  $lock = Lock-RunControl $p
  if (-not $lock) { return @{ ok = $false; reason = "run_control_busy" } }
  try {
    $o = Read-RunControl $p
    if (-not $o) { return @{ ok = $false; reason = "idle" } }
    if ($RunId -and $o.run_id -ne $RunId) { return @{ ok = $false; reason = "stale_run"; run_id = [string]$o.run_id } }
    if ($o.state -ne "running") { return @{ ok = $false; reason = "idle"; run_id = [string]$o.run_id } }
    if ($o.stop_requested) { return @{ ok = $true; already = $true; run_id = [string]$o.run_id } }
    $stopAt = (Get-Date).ToString("o")
    Set-RunControlField $o "stop_requested" $true
    Set-RunControlField $o "stop_at" $stopAt
    Set-RunControlField $o "updated_at" $stopAt
    Save-RunControl $p $o
    return @{ ok = $true; already = $false; run_id = [string]$o.run_id }
  } finally { Unlock-RunControl $lock $p }
}

function Request-PlatformSkip([string]$BaseDir, [string]$RunId, [string]$Platform) {
  $p = Get-RunControlPath $BaseDir
  $lock = Lock-RunControl $p
  if (-not $lock) { return @{ ok = $false; reason = "run_control_busy" } }
  try {
    $o = Read-RunControl $p
    if (-not $o) { return @{ ok = $false; reason = "idle" } }
    if ($RunId -and $o.run_id -ne $RunId) { return @{ ok = $false; reason = "stale_run"; run_id = [string]$o.run_id } }
    if ($o.state -ne "running") { return @{ ok = $false; reason = "idle"; run_id = [string]$o.run_id } }
    $cur = [string]$o.current_platform
    $want = if ($Platform) { [string]$Platform } else { $cur }
    if (-not $want) { return @{ ok = $false; reason = "platform_unknown"; run_id = [string]$o.run_id } }
    if ($cur -and $want -ne $cur) { return @{ ok = $false; reason = "stale_platform"; run_id = [string]$o.run_id; platform = $cur } }
    if ($o.skip_platform -eq $want) { return @{ ok = $true; already = $true; run_id = [string]$o.run_id; platform = $want } }
    $skipAt = (Get-Date).ToString("o")
    Set-RunControlField $o "skip_platform" $want
    Set-RunControlField $o "skip_at" $skipAt
    Set-RunControlField $o "updated_at" $skipAt
    Save-RunControl $p $o
    return @{ ok = $true; already = $false; run_id = [string]$o.run_id; platform = $want }
  } finally { Unlock-RunControl $lock $p }
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
  $lock = Lock-RunControl $p
  if (-not $lock) { return }
  try {
    $o = Read-RunControl $p
    if (-not $o -or $o.run_id -ne $RunId) { return }
    Set-RunControlField $o "state" "complete"
    Set-RunControlField $o "skip_platform" ""
    Set-RunControlField $o "updated_at" ((Get-Date).ToString("o"))
    Save-RunControl $p $o
  } finally { Unlock-RunControl $lock $p }
}

function Close-RunControl([string]$BaseDir, [string]$RunId, [string]$State = "stopped", [switch]$OnlyIfRunning) {
  $p = Get-RunControlPath $BaseDir
  $lock = Lock-RunControl $p
  if (-not $lock) { return }
  try {
    $o = Read-RunControl $p
    if (-not $o -or $o.run_id -ne $RunId) { return }
    if ($OnlyIfRunning -and [string]$o.state -ne "running") { return }
    Set-RunControlField $o "state" $State
    Set-RunControlField $o "skip_platform" ""
    Set-RunControlField $o "updated_at" ((Get-Date).ToString("o"))
    Save-RunControl $p $o
  } finally { Unlock-RunControl $lock $p }
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
