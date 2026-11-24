# lib/run_plan.ps1 — 回合计划（已选平台按序）、停止语义、候选台账
# 纯逻辑，无 I/O、无网络，供 hub 与离线测试共用。

function New-RunPlan {
  param(
    [string[]]$Platforms = @(),
    [string[]]$Known = @()
  )
  $order = New-Object System.Collections.ArrayList
  foreach ($p in @($Platforms)) {
    $v = ([string]$p).Trim()
    if (-not $v) { continue }
    if ($Known.Count -gt 0 -and -not ($Known -contains $v)) { continue }
    if ($order -contains $v) { continue }
    [void]$order.Add($v)
  }
  return [pscustomobject]@{
    order = @($order.ToArray())
    count = $order.Count
    createdAt = (Get-Date).ToString("o")
  }
}

function Get-NextPlanItem {
  param($Plan, [int]$Index)
  if (-not $Plan) { return $null }
  $o = @($Plan.order)
  if ($Index -lt 0 -or $Index -ge $o.Count) { return $null }
  return $o[$Index]
}

function Get-PlanAdvance {
  param(
    [string]$Outcome = "platform_complete",
    [bool]$StopRequested = $false,
    [bool]$Emergency = $false,
    [bool]$SharedFailure = $false,
    [string]$Reason = "",
    [bool]$HasNext = $true
  )
  if ($Emergency) { return [pscustomobject]@{ advance = $false; halt = $true; global = $true; code = "emergency_stopped"; reason = "全局急停" } }
  if ($StopRequested) { return [pscustomobject]@{ advance = $false; halt = $true; global = $true; code = "stopped"; reason = "整轮停止" } }
  if ($SharedFailure) { return [pscustomobject]@{ advance = $false; halt = $true; global = $true; code = "global_failure"; reason = "共享依赖失败（Hub/登录）" } }
  if (-not $HasNext) { return [pscustomobject]@{ advance = $false; halt = $true; global = $false; code = "complete"; reason = "计划内平台已全部结束" } }
  return [pscustomobject]@{ advance = $true; halt = $false; global = $false; code = "advance"; reason = $Reason }
}

function New-CandidateLedger {
  return @{}
}

function Add-LedgerCandidate {
  param($Ledger, [string]$Key, [string]$Source = "", [string]$Platform = "")
  if (-not $Ledger -or -not $Key) { return }
  if (-not $Ledger.ContainsKey($Key)) {
    $Ledger[$Key] = [pscustomobject]@{
      key = $Key; platform = $Platform; source = $Source
      filter = ""; dispatched = $false; outcome = ""; reason = ""
      addedAt = (Get-Date).ToString("o"); dispatchedAt = ""; endedAt = ""
    }
  } elseif ($Source -and -not $Ledger[$Key].source) { $Ledger[$Key].source = $Source }
  return $Ledger[$Key]
}

function Set-LedgerFilter {
  param($Ledger, [string]$Key, [string]$Reason = "")
  if (-not $Ledger -or -not $Key -or -not $Ledger.ContainsKey($Key)) { return }
  $Ledger[$Key].filter = $Reason
}

function Set-LedgerDispatch {
  param($Ledger, [string]$Key)
  if (-not $Ledger -or -not $Key -or -not $Ledger.ContainsKey($Key)) { return $false }
  if ($Ledger[$Key].dispatched) { return $false }
  $Ledger[$Key].dispatched = $true
  $Ledger[$Key].dispatchedAt = (Get-Date).ToString("o")
  return $true
}

function Set-LedgerOutcome {
  param($Ledger, [string]$Key, [string]$Outcome, [string]$Reason = "")
  if (-not $Ledger -or -not $Key -or -not $Ledger.ContainsKey($Key)) { return $false }
  $e = $Ledger[$Key]
  if ($e.outcome -and $e.outcome -ne "pending") { return $false }
  if ($Outcome -eq "pending") { $e.outcome = "pending"; $e.reason = $Reason; return $true }
  $e.outcome = $Outcome
  $e.reason = $Reason
  $e.endedAt = (Get-Date).ToString("o")
  return $true
}

function Get-LedgerSummary {
  param($Ledger)
  $s = [ordered]@{
    total = 0; dispatched = 0; joined = 0; existing = 0; skipped = 0; failed = 0
    pending = 0; not_executed = 0; filtered = 0
  }
  if ($Ledger) {
    foreach ($k in $Ledger.Keys) {
      $e = $Ledger[$k]
      $s.total++
      if ($e.filter) { $s.filtered++; continue }
      if ($e.dispatched) { $s.dispatched++ }
      switch ([string]$e.outcome) {
        "joined" { $s.joined++ }
        "existing" { $s.existing++ }
        "skipped" { $s.skipped++ }
        "failed" { $s.failed++ }
        "pending" { $s.pending++ }
        default {
          if ($e.dispatched) { $s.not_executed++ } else { $s.not_executed++ }
        }
      }
    }
  }
  return [pscustomobject]$s
}

function Test-LedgerReconcile {
  param($Ledger)
  $s = Get-LedgerSummary $Ledger
  $terminal = $s.joined + $s.existing + $s.skipped + $s.failed
  return [pscustomobject]@{
    summary = $s
    terminal = $terminal
    accounted = ($terminal + $s.pending + $s.not_executed)
    ok = (($s.total - $s.filtered) -eq ($terminal + $s.pending + $s.not_executed))
  }
}

function Test-PlanSkipConsume {
  param($SkipState, [string]$Platform)
  if (-not $SkipState -or -not $Platform) { return $false }
  if ($SkipState.ContainsKey($Platform)) { return $false }
  $SkipState[$Platform] = $true
  return $true
}

function Wait-StopAck {
  param(
    [scriptblock]$Probe,
    [int]$TimeoutSec = 8,
    [int]$PollMs = 400
  )
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $tries = 0
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $tries++
    $r = $null
    try { $r = & $Probe } catch { $r = $false }
    if ($r) {
      return [pscustomobject]@{ acked = $true; timedOut = $false; tries = $tries; waitedMs = [int]$sw.Elapsed.TotalMilliseconds }
    }
    Start-Sleep -Milliseconds $PollMs
  }
  return [pscustomobject]@{ acked = $false; timedOut = $true; tries = $tries; waitedMs = [int]$sw.Elapsed.TotalMilliseconds }
}
