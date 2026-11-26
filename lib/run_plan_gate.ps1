# lib/run_plan_gate.ps1  (m14916)
# 目的：把「顺延只在已确认终态后推进」的闸门、台账收口与心跳从 run_plan.ps1 分离，
# 便于单测与灰部署；本文件只依赖 run_plan.ps1 / run_control.ps1 已定义的函数。

function Get-LedgerKey($Item) {
  if (-not $Item) { return "" }
  $id = ""
  foreach ($k in @("id","gid","h","hash")) {
    try { $v = [string]$Item.$k; if ($v) { $id = $v; break } } catch { }
  }
  $u = ""; try { $u = [string]$Item.u } catch { }
  $t = ""; try { $t = [string]$Item.t } catch { }
  return ($id + "|" + $u + "|" + $t)
}

function Get-LedgerPendingTerminal($Ledger) {
  if (-not $Ledger) { return 0 }
  $n = 0
  foreach ($k in @($Ledger.Keys)) {
    $e = $Ledger[$k]
    if (-not $e) { continue }
    if (-not $e.dispatched) { continue }
    if ($e.outcome) { continue }
    $n++
  }
  return $n
}


function Resolve-PlanAdvance {
  param(
    [string]$Outcome = "platform_complete",
    [bool]$StopRequested = $false,
    [bool]$Emergency = $false,
    [bool]$SharedFailure = $false,
    [bool]$PlatformAborted = $false,
    [bool]$HasNext = $false,
    [int]$PendingTerminal = 0
  )
  if ($StopRequested) { return @{ advance = $false; code = "stopped"; reason = "人工停止整轮" } }
  if ($Emergency) { return @{ advance = $false; code = "emergency_stopped"; reason = "全局急停" } }
  if ($SharedFailure) { return @{ advance = $false; code = "global_failure"; reason = "Hub 共享故障" } }
  if ($PlatformAborted) {
    if ($HasNext) { return @{ advance = $true; code = "platform_partial"; reason = "本平台已停止新派发，顺延下一平台" } }
    return @{ advance = $false; code = "partial_complete"; reason = "本平台已停止新派发，且无后续平台" }
  }
  if ($PendingTerminal -gt 0) {
    if ($HasNext) { return @{ advance = $true; code = "platform_partial"; reason = ("本平台有 " + $PendingTerminal + " 个已派发未确认，停止该平台新派发并顺延") } }
    return @{ advance = $false; code = "partial_complete"; reason = ("本平台有 " + $PendingTerminal + " 个已派发未确认，且无后续平台") }
  }
  return (Get-PlanAdvance -Outcome $Outcome -StopRequested $StopRequested -Emergency $Emergency -SharedFailure $SharedFailure -HasNext $HasNext)
}

function Set-LedgerNotExecuted($Ledger) {
  if (-not $Ledger) { return 0 }
  $n = 0
  foreach ($k in @($Ledger.Keys)) {
    $e = $Ledger[$k]
    if (-not $e) { continue }
    if ($e.dispatched) { continue }
    if ($e.outcome) { continue }
    $e | Add-Member -NotePropertyName outcome -NotePropertyValue "not_executed" -Force
    $e | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToString("o")) -Force
    $n++
  }
  return $n
}


function Write-PlanHeartbeat([string]$BaseDir, [string]$RunId, [string]$Platform) {
  if (-not $RunId) { return $false }
  try {
    $p = Get-RunControlPath $BaseDir
    $o = Read-RunControl $p
    if (-not $o) { return $false }
    if ([string]$o.run_id -ne [string]$RunId) { return $false }
    $now = (Get-Date).ToString("o")
    $o | Add-Member -NotePropertyName heartbeat_at -NotePropertyValue $now -Force
    $o | Add-Member -NotePropertyName updated_at -NotePropertyValue $now -Force
    if ($Platform) { $o.current_platform = $Platform }
    Save-RunControl $p $o
    return $true
  } catch { return $false }
}
function Set-LedgerUnconfirmed($Ledger) {
  if (-not $Ledger) { return 0 }
  $n = 0
  foreach ($k in @($Ledger.Keys)) {
    $e = $Ledger[$k]
    if (-not $e) { continue }
    if (-not $e.dispatched) { continue }
    if ($e.outcome) { continue }
    $e | Add-Member -NotePropertyName outcome -NotePropertyValue "unconfirmed" -Force
    $e | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToString("o")) -Force
    $n++
  }
  return $n
}

