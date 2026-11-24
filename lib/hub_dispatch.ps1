# lib/hub_dispatch.ps1 — 真实 hub 的不可变派发身份与迟到回执隔离
# 依赖 run_plan.ps1 / run_plan_gate.ps1 已加载（Get-LedgerKey / Add-LedgerCandidate / Set-LedgerDispatch / Set-LedgerOutcome）。

function Initialize-HubRound {
  param(
    $State,
    [string]$RunId = "",
    [string[]]$Platforms = @(),
    [bool]$External = $false
  )
  $plan = @($Platforms | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
  $State.plan = $plan
  $State.planIndex = 0
  $State.planRunId = [string]$RunId
  $State.skipApplied = @{}
  $State.ledger = @{}
  $State.platformAbort = $false
  $State.abortReason = ""
  $State.platformStats = @{}
  $State.dispatches = @{}
  $State.joinInflight = $null
  $State.lateReceipts = @()
  $State.reportText = ""
  $State.stopRequested = $false
  $State.stopMode = ""
  $State.externalRun = [bool]$External
  $State.unconfirmed = 0
  foreach ($p in $plan) {
    $State.platformStats[[string]$p] = (New-PlatformResult -Platform ([string]$p) -Result "未运行")
  }
  return $State
}

function Get-HubPlatformStat {
  param($State, [string]$Platform)
  if (-not $State -or -not $Platform) { return $null }
  try {
    if (-not $State.platformStats) { $State.platformStats = @{} }
    if (-not $State.platformStats.ContainsKey($Platform)) {
      $State.platformStats[$Platform] = (New-PlatformResult -Platform $Platform -Result "未运行")
    }
    return $State.platformStats[$Platform]
  } catch { return $null }
}

function Set-HubPlatformResult {
  param($State, [string]$Platform, [string]$Result = "", [string]$Reason = "")
  $st = Get-HubPlatformStat -State $State -Platform $Platform
  if (-not $st) { return }
  if ($PSBoundParameters.ContainsKey("Result") -and $Result) { $st.result = $Result }
  if ($PSBoundParameters.ContainsKey("Reason") -and $Reason) { $st.reason = $Reason }
}

function Complete-HubPlatform {
  param($State, [string]$Platform, [string]$Result = "", [string]$Reason = "", $Ledger = $null)
  $st = Get-HubPlatformStat -State $State -Platform $Platform
  if (-not $st) { return }
  if ($Result) { $st.result = $Result }
  elseif ([string]$st.result -eq "未运行" -or [string]$st.result -eq "进行中") { $st.result = "完成" }
  if ($Reason) { $st.reason = $Reason }
  if ($Ledger) {
    $pending = 0
    foreach ($k in @($Ledger.Keys)) {
      $e = $Ledger[$k]
      if ([string]$e.platform -eq $Platform -and [bool]$e.dispatched -and -not $e.outcome) { $pending++ }
    }
    if ($pending -gt 0) { $st.unconfirmed = [int]$st.unconfirmed + $pending }
  }
}

function New-HubJoinDispatch {
  param($State, $Item, [string]$Platform, $TaskId)
  if (-not $State -or -not $Item) { return $null }
  if (-not $State.dispatches) { $State.dispatches = @{} }
  if (-not $State.ledger) { $State.ledger = @{} }
  $key = ""
  try { $key = [string](Get-LedgerKey $Item) } catch { $key = "" }
  if (-not $key) { return $null }
  $existing = $null
  try { if ($State.ledger.ContainsKey($key)) { $existing = $State.ledger[$key] } } catch { }
  if ($existing -and ($existing.dispatched -or $existing.outcome)) { return $null }
  $entry = Add-LedgerCandidate -Ledger $State.ledger -Key $key -Source ([string]$Item.src) -Platform $Platform
  if (-not (Set-LedgerDispatch -Ledger $State.ledger -Key $key)) { return $null }
  $st = Get-HubPlatformStat -State $State -Platform $Platform
  if ($st -and ([string]$st.result -eq "未运行" -or [string]$st.result -eq "准备")) { $st.result = "进行中" }
  $d = [pscustomobject]@{
    id = [string]$TaskId
    run_id = [string]$State.planRunId
    platform = [string]$Platform
    ledger_key = $key
    item = $Item
    dispatched_at = (Get-Date).ToString("o")
    resolved = $false
    outcome = ""
    resolved_at = ""
  }
  $State.dispatches[[string]$TaskId] = $d
  $State.joinInflight = $d
  $State.pending = @{ kind = "join"; id = $TaskId; cand = $Item }
  return $d
}

function Add-HubLateReceipt {
  param($State, [string]$TaskId, [string]$Value, [string]$Reason = "late")
  if (-not $State) { return }
  if (-not $State.lateReceipts) { $State.lateReceipts = @() }
  $rec = [pscustomobject]@{
    task_id = [string]$TaskId
    value = [string]$Value
    reason = [string]$Reason
    at = (Get-Date).ToString("o")
  }
  $State.lateReceipts = @(@($State.lateReceipts) + $rec)
  if (@($State.lateReceipts).Count -gt 100) {
    $State.lateReceipts = @($State.lateReceipts | Select-Object -Last 100)
  }
}

function Test-HubDispatchExpired {
  param($Dispatch, [int]$TimeoutSec = 120)
  if (-not $Dispatch) { return $true }
  try {
    $t = [datetime]::Parse([string]$Dispatch.dispatched_at)
    return (((Get-Date) - $t).TotalSeconds -ge $TimeoutSec)
  } catch { return $true }
}

function Resolve-HubJoinReceipt {
  param(
    $State,
    [string]$CurrentPlatform = "",
    [string]$TaskId = "",
    [string]$Value = "",
    [string]$Error = ""
  )
  if (-not $State) { return @{ status = "late"; reason = "no_state" } }
  if (-not $State.dispatches) { $State.dispatches = @{} }
  $d = $null
  if ($TaskId) {
    try { if ($State.dispatches.ContainsKey($TaskId)) { $d = $State.dispatches[$TaskId] } } catch { }
  }
  if (-not $d -and $State.joinInflight) {
    $inf = $State.joinInflight
    if (-not $TaskId -or [string]$inf.id -eq $TaskId) { $d = $inf }
  }
  if (-not $d) {
    Add-HubLateReceipt -State $State -TaskId $TaskId -Value $Value -Reason "unknown_task"
    return @{ status = "late"; reason = "unknown_task"; task_id = $TaskId; value = $Value }
  }
  if ($d.resolved) {
    Add-HubLateReceipt -State $State -TaskId $TaskId -Value $Value -Reason "duplicate"
    return @{ status = "duplicate"; reason = "duplicate"; dispatch = $d; task_id = $TaskId; value = $Value }
  }
  $cur = [string]$CurrentPlatform
  if ($cur -and [string]$d.platform -ne $cur) {
    Add-HubLateReceipt -State $State -TaskId $TaskId -Value $Value -Reason ("late_platform:" + [string]$d.platform)
    return @{ status = "late"; reason = "late_platform"; dispatch = $d; task_id = $TaskId; value = $Value }
  }
  if ([string]$d.run_id -and [string]$State.planRunId -and [string]$d.run_id -ne [string]$State.planRunId) {
    Add-HubLateReceipt -State $State -TaskId $TaskId -Value $Value -Reason "late_run"
    return @{ status = "late"; reason = "late_run"; dispatch = $d; task_id = $TaskId; value = $Value }
  }
  $v = [string]$Value
  if (-not $v -and $Error) { $v = "failed" }
  $outcome = Get-HubReceiptOutcome -Value $v
  return @{ status = "applied"; dispatch = $d; item = $d.item; ledger_key = [string]$d.ledger_key; value = $v; outcome = $outcome; task_id = $TaskId; abort = ($outcome -eq "unconfirmed" -or $outcome -eq "global_failure") }
}

function Get-HubReceiptOutcome {
  param([string]$Value = "", $Disposition = $null)
  $v = [string]$Value
  if ($v -eq "already") { return "existing" }
  if ($v -eq "joined") {
    if ($Disposition) {
      if ([int]$Disposition.existing -gt 0) { return "existing" }
      if ([int]$Disposition.local -gt 0) { return "local" }
      if ([int]$Disposition.failed -gt 0) { return "failed" }
    }
    return "joined"
  }
  if ($v -eq "unknown" -or -not $v) { return "unconfirmed" }
  if ($v -eq "shared_failure" -or $v -eq "fatal" -or $v -eq "browser_down") { return "global_failure" }
  if ($v -eq "stale" -or $v -eq "request_sent" -or $v -eq "not_found" -or $v -eq "approval" -or $v -eq "visited") { return "skipped" }
  return "failed"
}

function Get-HubReceiptCounts {
  param([string]$Value = "", $Disposition = $null)
  $v = [string]$Value
  if ($v -eq "already") { return @{ joined = 0; existing = 1; local = 0; failed = 0; unconfirmed = 0; skipped = 0 } }
  if ($v -eq "joined") {
    if ($Disposition) {
      return @{ joined = [int]$Disposition.joined; existing = [int]$Disposition.existing; local = [int]$Disposition.local; failed = [int]$Disposition.failed; unconfirmed = 0; skipped = 0 }
    }
    return @{ joined = 1; existing = 0; local = 0; failed = 0; unconfirmed = 0; skipped = 0 }
  }
  if ($v -eq "unknown" -or -not $v) { return @{ joined = 0; existing = 0; local = 0; failed = 0; unconfirmed = 1; skipped = 0 } }
  if ($v -eq "shared_failure" -or $v -eq "fatal" -or $v -eq "browser_down") { return @{ joined = 0; existing = 0; local = 0; failed = 0; unconfirmed = 0; skipped = 0 } }
  if ($v -eq "stale" -or $v -eq "request_sent" -or $v -eq "not_found" -or $v -eq "approval" -or $v -eq "visited") { return @{ joined = 0; existing = 0; local = 0; failed = 0; unconfirmed = 0; skipped = 1 } }
  return @{ joined = 0; existing = 0; local = 0; failed = 1; unconfirmed = 0; skipped = 0 }
}

function Complete-HubJoinReceipt {
  param($State, $Dispatch, [string]$Outcome = "", $Before = $null)
  if (-not $State -or -not $Dispatch) { return }
  $d = $Dispatch
  if ($d.resolved) { return }
  $d.resolved = $true
  $d.resolved_at = (Get-Date).ToString("o")
  $d.outcome = [string]$Outcome
  if ($State.joinInflight -and [string]$State.joinInflight.id -eq [string]$d.id) { $State.joinInflight = $null }
  if ($State.pending -and [string]$State.pending.id -eq [string]$d.id) { $State.pending = $null }
  $st = Get-HubPlatformStat -State $State -Platform ([string]$d.platform)
  if ($st -and $Before) {
    $st.joined = [int]$st.joined + ([int]$State.joined - [int]$Before.joined)
    $st.existing = [int]$st.existing + ([int]$State.existing - [int]$Before.existing)
    $st.local = [int]$st.local + ([int]$State.local - [int]$Before.local)
    $st.failed = [int]$st.failed + ([int]$State.failed - [int]$Before.failed)
    $st.unconfirmed = [int]$st.unconfirmed + ([int]$State.unconfirmed - [int]$Before.unconfirmed)
    $st.skipped = [int]$st.skipped + ([int]$State.skipped - [int]$Before.skipped)
    if ($st.result -eq "未运行") { $st.result = "进行中" }
  }
}
