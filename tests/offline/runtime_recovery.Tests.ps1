param()
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\run_control.ps1")
. (Join-Path $root "lib\pipeline_status.ps1")
. (Join-Path $root "lib\run_recovery.ps1")

$pass = 0; $fail = 0
function T([string]$name, [scriptblock]$sb) {
  try { & $sb; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: " + $_.Exception.Message }
}
function A($cond, [string]$msg) { if (-not $cond) { throw $msg } }
function New-TempBase {
  $p = Join-Path ([System.IO.Path]::GetTempPath()) ("gops-recovery-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $p -Force | Out-Null
  $env:GOPS_RUN_CONTROL_FILE = Join-Path $p "run_control.json"
  $env:GOPS_STATE_ROOT = $p
  return $p
}
function New-State([string]$RunId) {
  return [pscustomobject]@{
    running = $true; planRunId = $RunId; externalRun = $false
    started = (Get-Date).AddMinutes(-30); lastTaskAt = (Get-Date)
    joinInflight = $null; plan = @("Telegram"); planIndex = 0
    queue = (New-Object System.Collections.Queue); candidates = @{}
    phase = "join"; task = "x"; activePlatform = "Telegram"; activeAt = ""
    current = "x"; stopRequested = $false; stopMode = ""; platformAbort = $false
    abortReason = ""; pending = $null
  }
}

$oldRc = $env:GOPS_RUN_CONTROL_FILE
$oldRoot = $env:GOPS_STATE_ROOT
$oldStop = $env:GOPS_STOP_FILE
$env:GOPS_RUN_CONTROL_FILE = ""
$env:GOPS_STATE_ROOT = ""
$env:GOPS_STOP_FILE = ""
try {
  T "owner-pid-parsed-from-run-id" {
    A ((Get-RunOwnerProcessId "run_all-20260102-030405-1234") -eq 1234) "run_all pid"
    A ((Get-RunOwnerProcessId "run_daily-20260102-030405-9876") -eq 9876) "run_daily pid"
    A ((Get-RunOwnerProcessId "hub-20260102-030405-abcdef") -eq 0) "hub has no pid"
  }

  T "owner-alive-and-pid-reuse" {
    $s = @{ owner_pid = $PID; started_at = (Get-Date).AddMinutes(-1).ToString("o") }
    A (Test-RunControlOwnerAlive -Status $s -RunId "run_all-x") "current process is alive"
    $s2 = @{ owner_pid = $PID; started_at = "2000-01-01T00:00:00" }
    A (-not (Test-RunControlOwnerAlive -Status $s2 -RunId "run_all-x")) "pid reuse must be dead"
    $s3 = @{ owner_pid = 2147483647; started_at = (Get-Date).ToString("o") }
    A (-not (Test-RunControlOwnerAlive -Status $s3 -RunId "run_all-x")) "missing pid must be dead"
    A (Test-RunControlOwnerAlive -Status @{ owner_pid = 0 } -RunId "hub-x") "unknown owner must be treated alive"
  }

  T "register-rejects-live-owner-and-reclaims-dead" {
    $b = New-TempBase
    $a = "run_all-20260102-030405-" + $PID
    $r1 = Register-RunControl -BaseDir $b -RunId $a -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID -OwnerKind "run_all"
    A $r1.ok ("first register: " + $r1.reason)
    $bRun = "legacy-run-without-pid"
    $r2 = Register-RunControl -BaseDir $b -RunId $bRun -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID -OwnerKind "run_all"
    A (-not $r2.ok) "live owner must not be overwritten"
    A ($r2.reason -eq "run_active") ("reason=" + $r2.reason)
    $env:GOPS_RUN_CONTROL_FILE = Join-Path $b "run_control.json"
    $stale = @{ run_id = $bRun; state = "running"; owner_pid = 0; updated_at = (Get-Date).ToString("o") }
    Save-RunControl (Get-RunControlPath $b) $stale
    $r3 = Register-RunControl -BaseDir $b -RunId "run_all-20260102-030407-888888" -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID -OwnerKind "run_all"
    A (-not $r3.ok) "legacy unknown owner must not be reclaimed"
    $env:GOPS_RUN_CONTROL_FILE = ""
    Remove-Item $b -Recurse -Force
  }

  T "register-reclaims-dead-owner-and-backups" {
    $b = New-TempBase
    $dead = 2147483647
    $a = "run_all-20260102-030405-" + $dead
    $null = Register-RunControl -BaseDir $b -RunId $a -Platforms @("Telegram") -Current "Telegram" -OwnerPid $dead -OwnerKind "run_all"
    $c = "run_all-20260102-030406-" + $PID
    $r = Register-RunControl -BaseDir $b -RunId $c -Platforms @("Telegram","Facebook") -Current "Facebook" -OwnerPid $PID -OwnerKind "run_all"
    A $r.ok ("reclaim: " + $r.reason)
    $rc = Read-RunControl (Get-RunControlPath $b)
    A ([string]$rc.run_id -eq $c) "new run id"
    A ([int]$rc.owner_pid -eq $PID) "owner pid stored"
    A (@(Get-ChildItem $b -Filter "run_control.json.stale.*").Count -ge 1) "stale backup written"
    Remove-Item $b -Recurse -Force
  }

  T "pipeline-close-only-matching-run" {
    $b = New-TempBase
    $a = New-PipelineStatus -RunId "run_a" -Platforms @("Telegram") -Phases @("hub")
    Save-PipelineStatus -Path (Get-PipelineStatusPath -BaseDir $b) -Status $a
    A ((@($a.phases) -join ",") -eq "hub") "phases field"
    A (-not (Close-PipelineStatusForRun -BaseDir $b -RunId "run_b" -State "stopped")) "other run not closed"
    $v = Get-PipelineStatusView -BaseDir $b
    A ([string]$v.state -eq "running") "other run stays running"
    A (Close-PipelineStatusForRun -BaseDir $b -RunId "run_a" -State "stopped" -Error "x") "matching run closed"
    $v2 = Get-PipelineStatusView -BaseDir $b
    A ([string]$v2.state -eq "stopped") "state stopped"
    A (-not (Close-PipelineStatusForRun -BaseDir $b -RunId "run_a" -State "failed" -OnlyIfRunning)) "only-if-running no-op after close"
    Remove-Item $b -Recurse -Force
  }

  T "sparse-run-control-record-tolerates-missing-optional-fields" {
    $b = New-TempBase
    $rid = "hub-20260102-030405-sparse"
    $sparse = [pscustomobject]@{ run_id = $rid; state = "running"; owner_pid = 0; owner_kind = "hub" }
    Save-RunControl (Get-RunControlPath $b) $sparse
    $rs = Request-RunStop -BaseDir $b -RunId $rid
    A $rs.ok ("stop request: " + $rs.reason)
    $afterStop = Read-RunControl (Get-RunControlPath $b)
    A ([bool]$afterStop.stop_requested) "stop_requested added"
    A ([string]$afterStop.stop_at) "stop_at added"
    Close-RunControl -BaseDir $b -RunId $rid -State "stopped" -OnlyIfRunning
    $afterClose = Read-RunControl (Get-RunControlPath $b)
    A ([string]$afterClose.state -eq "stopped") ("state=" + $afterClose.state)
    A ($afterClose.PSObject.Properties.Name -contains "skip_platform") "skip_platform added"
    Remove-Item $b -Recurse -Force
  }

  T "ghost-run-control-closed" {
    $b = New-TempBase
    $rid = "run_daily-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID
    Close-RunControl -BaseDir $b -RunId $rid -State "stopped" | Out-Null
    $r = Test-GopsRoundGhost -BaseDir $b -State (New-State $rid)
    A ($r.ghost -eq $true) "must be ghost"
    A ($r.reason -eq "run_control_closed") ("reason=" + $r.reason)
    Remove-Item $b -Recurse -Force
  }

  T "ghost-pipeline-closed" {
    $b = New-TempBase
    $rid = "run_daily-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID
    $p = New-PipelineStatus -RunId $rid -Platforms @("Telegram")
    $p.state = "stopped"
    $p.updated_at = (Get-Date).AddMinutes(-5).ToString("o")
    Save-PipelineStatus -Path (Get-PipelineStatusPath -BaseDir $b) -Status $p
    $r = Test-GopsRoundGhost -BaseDir $b -State (New-State $rid)
    A ($r.ghost -eq $true) "must be ghost"
    A ($r.reason -eq "pipeline_closed") ("reason=" + $r.reason)
    Remove-Item $b -Recurse -Force
  }

  T "ghost-owner-dead-external" {
    $b = New-TempBase
    $dead = 2147483647
    $rid = "run_all-20260102-030405-" + $dead
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $dead -OwnerKind "run_all"
    $s = New-State $rid; $s.externalRun = $true
    $r = Test-GopsRoundGhost -BaseDir $b -State $s
    A ($r.ghost -eq $true) "must be ghost"
    A ($r.reason -eq "owner_dead") ("reason=" + $r.reason)
    Remove-Item $b -Recurse -Force
  }

  T "ghost-heartbeat-and-inflight-guard" {
    $b = New-TempBase
    $rid = "run_all-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID
    $s = New-State $rid; $s.externalRun = $true; $s.lastTaskAt = (Get-Date).AddMinutes(-20)
    $r = Test-GopsRoundGhost -BaseDir $b -State $s
    A ($r.ghost -eq $false) "live external owner must not be reclaimed by heartbeat"
    A ($r.reason -eq "owner_alive") ("reason=" + $r.reason)
    $sManual = New-State $rid; $sManual.externalRun = $false; $sManual.lastTaskAt = (Get-Date).AddMinutes(-20)
    $rm = Test-GopsRoundGhost -BaseDir $b -State $sManual
    A ($rm.ghost -eq $true) "stale manual heartbeat must be ghost"
    A ($rm.reason -eq "heartbeat_stale") ("reason=" + $rm.reason)
    $s2 = New-State $rid; $s2.externalRun = $false; $s2.lastTaskAt = (Get-Date).AddMinutes(-20)
    $s2.joinInflight = @{ dispatched_at = (Get-Date).AddSeconds(-10).ToString("o") }
    $r2 = Test-GopsRoundGhost -BaseDir $b -State $s2
    A ($r2.ghost -eq $false -and $r2.reason -eq "join_inflight") ("reason=" + $r2.reason)
    Remove-Item $b -Recurse -Force
  }

  T "ghost-live-round-not-reclaimed" {
    $b = New-TempBase
    $rid = "run_all-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID
    $p = New-PipelineStatus -RunId $rid -Platforms @("Telegram")
    Save-PipelineStatus -Path (Get-PipelineStatusPath -BaseDir $b) -Status $p
    $s = New-State $rid; $s.externalRun = $true; $s.lastTaskAt = (Get-Date)
    $r = Test-GopsRoundGhost -BaseDir $b -State $s
    A ($r.ghost -eq $false) ("live round flagged: " + $r.reason)
    Remove-Item $b -Recurse -Force
  }

  T "ghost-other-run-active" {
    $b = New-TempBase
    $a = "run_all-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $a -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID
    $s = New-State "run_all-20260102-030400-$PID"; $s.lastTaskAt = (Get-Date)
    $r = Test-GopsRoundGhost -BaseDir $b -State $s
    A ($r.ghost -eq $true) "stale memory must yield"
    A ($r.reason -eq "other_run_active") ("reason=" + $r.reason)
    Remove-Item $b -Recurse -Force
  }

  T "repair-resets-memory-and-closes-matching-files" {
    $b = New-TempBase
    $rid = "run_all-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID
    $p = New-PipelineStatus -RunId $rid -Platforms @("Telegram")
    Save-PipelineStatus -Path (Get-PipelineStatusPath -BaseDir $b) -Status $p
    Close-RunControl -BaseDir $b -RunId $rid -State "stopped" | Out-Null
    $s = New-State $rid
    $r = Repair-GopsGhostState -BaseDir $b -State $s
    A ($r.repaired -eq $true) "repaired"
    A ($s.running -eq $false) "running reset"
    A ([string]$s.phase -eq "idle") "phase reset"
    A ([string]$s.planRunId -eq "") "run id cleared"
    A ($s.queue.Count -eq 0) "queue cleared"
    A ($s.candidates.Count -eq 0) "candidates cleared"
    $v = Get-PipelineStatusView -BaseDir $b
    A ([string]$v.state -eq "failed") ("pipeline=" + $v.state)
    Remove-Item $b -Recurse -Force
  }

  T "concurrent-stop-and-platform-update-preserve-both" {
    $b = New-TempBase
    $rid = "run_all-20260102-030405-" + $PID
    $null = Register-RunControl -BaseDir $b -RunId $rid -Platforms @("Telegram") -Current "Telegram" -OwnerPid $PID -OwnerKind "run_all"
    $rc = Join-Path $b "run_control.json"
    $child = Join-Path $b "mutate.ps1"
    $code = @'
param($Root,$Rc,$Run,$Mode)
$env:GOPS_RUN_CONTROL_FILE = $Rc
. (Join-Path $Root "lib\run_control.ps1")
if ($Mode -eq "stop") { for ($i = 0; $i -lt 30; $i++) { $null = Request-RunStop -BaseDir $Root -RunId $Run } }
else { for ($i = 0; $i -lt 30; $i++) { $null = Update-RunControlPlatform -BaseDir $Root -RunId $Run -Current "Steam" } }
'@
    [System.IO.File]::WriteAllText($child, $code, (New-Object System.Text.UTF8Encoding($false)))
    $p1 = Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$child,$root,$rc,$rid,"stop") -WindowStyle Hidden -PassThru
    $p2 = Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$child,$root,$rc,$rid,"update") -WindowStyle Hidden -PassThru
    $null = $p1.WaitForExit(30000)
    $null = $p2.WaitForExit(30000)
    $o = Read-RunControl $rc
    A ($o.stop_requested -eq $true) "stop lost under concurrency"
    A ([string]$o.current_platform -eq "Steam") ("current lost: " + $o.current_platform)
    Remove-Item $b -Recurse -Force
  }

  "RESULT pass=$pass fail=$fail"
  if ($fail -gt 0) { exit 1 }
} finally {
  $env:GOPS_RUN_CONTROL_FILE = $oldRc
  $env:GOPS_STATE_ROOT = $oldRoot
  $env:GOPS_STOP_FILE = $oldStop
}
