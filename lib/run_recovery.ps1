# lib/run_recovery.ps1 -- evidence-based recovery for in-memory hub rounds.
# A hub round is only reclaimed when another durable signal proves it ended:
# its run_control stopped/complete, its pipeline status closed, its external
# owner process is gone, or its worker heartbeat expired. Unknown owners and
# live in-flight join dispatches are never reclaimed.
# Depends on run_control.ps1 and pipeline_status.ps1 being loaded.

function Test-GopsRoundGhost {
  param(
    [string]$BaseDir,
    $State,
    [datetime]$Now = (Get-Date),
    [int]$HeartbeatSec = 720,
    [int]$GraceSec = 45
  )
  try {
    if (-not $State) { return @{ ghost = $false; reason = "no_state"; run_id = "" } }
    if (-not [bool]$State.running) { return @{ ghost = $false; reason = "not_running"; run_id = [string]$State.planRunId } }
    $rid = [string]$State.planRunId
    if (-not $rid) { return @{ ghost = $false; reason = "no_run_id"; run_id = "" } }

    $rc = $null
    try { $rc = Read-RunControl (Get-RunControlPath $BaseDir) } catch { }
    if ($rc) {
      if ([string]$rc.run_id -ne $rid) {
        # Another run owns the durable control record. The in-memory round is
        # stale even if that other owner is itself about to be reclaimed.
        if ([string]$rc.state -eq "running") {
          return @{ ghost = $true; reason = "other_run_active"; run_id = $rid; other_run_id = [string]$rc.run_id }
        }
      } elseif ([string]$rc.state -ne "running") {
        return @{ ghost = $true; reason = "run_control_closed"; run_id = $rid }
      }
    }

    $pv = $null
    try { $pv = Get-PipelineStatusView -BaseDir $BaseDir } catch { }
    if ($pv -and [string]$pv.run_id -eq $rid) {
      $st = [string]$pv.state
      if (@("complete", "failed", "stopped") -contains $st) {
        $upd = $null
        try { if ($pv.updated_at) { $upd = [datetime]::Parse([string]$pv.updated_at) } } catch { }
        if (-not $upd -or ($Now - $upd).TotalSeconds -ge $GraceSec) {
          return @{ ghost = $true; reason = "pipeline_closed"; run_id = $rid }
        }
      }
    }

    $ownerAlive = $true
    if ([bool]$State.externalRun) {
      $ownerAlive = Test-RunControlOwnerAlive -Status $rc -RunId $rid -BaseDir $BaseDir
      if (-not $ownerAlive) {
        return @{ ghost = $true; reason = "owner_dead"; run_id = $rid }
      }
    }

    $last = $null
    try { if ($State.lastTaskAt) { $last = [datetime]::Parse([string]$State.lastTaskAt) } } catch { }
    if (-not $last) { try { if ($State.started) { $last = [datetime]$State.started } } catch { } }
    if ($last -and ($Now - $last).TotalSeconds -ge $HeartbeatSec) {
      # An external owner that is still alive may simply be waiting on a slow
      # worker. Its own wait timeout owns the cleanup decision; never reclaim a
      # live external round on heartbeat alone.
      if ([bool]$State.externalRun -and $ownerAlive) {
        return @{ ghost = $false; reason = "owner_alive"; run_id = $rid }
      }
      $inf = $State.joinInflight
      if ($inf) {
        $disp = $null
        try { if ($inf.dispatched_at) { $disp = [datetime]::Parse([string]$inf.dispatched_at) } } catch { }
        if ($disp -and ($Now - $disp).TotalSeconds -lt 120) {
          return @{ ghost = $false; reason = "join_inflight"; run_id = $rid }
        }
      }
      return @{ ghost = $true; reason = "heartbeat_stale"; run_id = $rid }
    }

    return @{ ghost = $false; reason = "alive"; run_id = $rid }
  } catch {
    return @{ ghost = $false; reason = ("error:" + $_.Exception.Message); run_id = "" }
  }
}

function Reset-GopsGhostState {
  param([string]$BaseDir, $State, [string]$Reason = "ghost")
  $rid = ""
  $rcClosed = $false
  try { $rid = [string]$State.planRunId } catch { }
  try {
    $State.running = $false
    $State.phase = "idle"
    $State.task = ""
    $State.activePlatform = ""
    $State.activeAt = ""
    $State.current = "准备开始"
    $State.stopRequested = $false
    $State.stopMode = ""
    $State.platformAbort = $false
    $State.abortReason = ""
    $State.pending = $null
    $State.joinInflight = $null
    $State.lastTaskAt = $null
    $State.candidates = @{}
    $State.plan = @()
    $State.planIndex = 0
    $State.planRunId = ""
    if ($State.queue) { $State.queue.Clear() }
  } catch { }
  if ($rid) {
    try {
      $rc = Read-RunControl (Get-RunControlPath $BaseDir)
      if ($rc -and [string]$rc.run_id -eq $rid -and [string]$rc.state -eq "running") {
        Close-RunControl -BaseDir $BaseDir -RunId $rid -State "stopped" -OnlyIfRunning
        $rcClosed = $true
      }
    } catch { }
    try { Close-PipelineStatusForRun -BaseDir $BaseDir -RunId $rid -State "failed" -Error ("ghost: " + $Reason) -OnlyIfRunning | Out-Null } catch { }
  }
  return @{ repaired = $true; reason = $Reason; run_id = $rid; run_control_closed = $rcClosed }
}

function Repair-GopsGhostState {
  param(
    [string]$BaseDir,
    $State,
    [datetime]$Now = (Get-Date),
    [int]$HeartbeatSec = 720,
    [int]$GraceSec = 45
  )
  $test = Test-GopsRoundGhost -BaseDir $BaseDir -State $State -Now $Now -HeartbeatSec $HeartbeatSec -GraceSec $GraceSec
  if (-not $test -or -not [bool]$test.ghost) {
    return @{ repaired = $false; reason = $(if ($test) { [string]$test.reason } else { "test_failed" }); run_id = "" }
  }
  return Reset-GopsGhostState -BaseDir $BaseDir -State $State -Reason ([string]$test.reason)
}
