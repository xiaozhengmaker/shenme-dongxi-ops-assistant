# tests/offline/run_plan.Tests.ps1
# 覆盖：计划构建（0/1/多/去重/未知剔除/顺序保持）、顺延决策矩阵、
#       skip 一次性、停止回执超时、候选台账六态与对账、计划持久化（JSON 往返）。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$lib = Join-Path $root "lib\run_plan.ps1"
if (-not (Test-Path $lib)) { $lib = Join-Path $PSScriptRoot "..\..\lib\run_plan.ps1" }
. $lib
"loaded: $lib"

$known = @("Facebook","Telegram","Reddit","WhatsApp","Steam")

T "plan-empty" {
  $p = New-RunPlan -Platforms @() -Known $known
  if ($p.count -ne 0) { throw "count=$($p.count)" }
}

T "plan-single" {
  $p = New-RunPlan -Platforms @("Telegram") -Known $known
  if ($p.count -ne 1 -or $p.order[0] -ne "Telegram") { throw "order=$($p.order -join ',')" }
}

T "plan-multi-order-and-dedupe" {
  $p = New-RunPlan -Platforms @("Steam","Twitter","Telegram","Steam") -Known $known
  if (($p.order -join ">") -ne "Steam>Telegram") { throw "order=$($p.order -join '>')" }
}

T "plan-unknown-dropped" {
  $p = New-RunPlan -Platforms @("Discord","Telegram") -Known $known
  if ($p.order -ne "Telegram") { throw "order=$($p.order -join '>')" }
}

T "plan-persist-json-roundtrip" {
  $p = New-RunPlan -Platforms @("Telegram","Steam") -Known $known
  $j = $p | ConvertTo-Json -Depth 4
  $b = $j | ConvertFrom-Json
  if (($b.order -join ">") -ne "Telegram>Steam") { throw "roundtrip=$($b.order -join '>')" }
  if ($b.count -ne 2) { throw "count=$($b.count)" }
}

T "advance-platform-complete-has-next" {
  $d = Get-PlanAdvance -Outcome "platform_complete" -HasNext $true
  if (-not $d.advance -or $d.halt) { throw "advance=$($d.advance) halt=$($d.halt)" }
}

T "advance-no-candidates" { $d = Get-PlanAdvance -Outcome "no_candidates" -HasNext $true; if (-not $d.advance) { throw "not advance" } }
T "advance-cooldown"      { $d = Get-PlanAdvance -Outcome "cooldown" -HasNext $true;      if (-not $d.advance) { throw "not advance" } }
T "advance-platform-failure" { $d = Get-PlanAdvance -Outcome "platform_failure" -HasNext $true; if (-not $d.advance) { throw "not advance" } }

T "halt-stop" {
  $d = Get-PlanAdvance -Outcome "stop" -StopRequested $true -HasNext $true
  if ($d.advance -or -not $d.halt -or $d.code -ne "stopped") { throw "code=$($d.code)" }
}

T "halt-emergency" {
  $d = Get-PlanAdvance -Outcome "emergency" -Emergency $true -HasNext $true
  if ($d.advance -or $d.code -ne "emergency_stopped" -or -not $d.global) { throw "code=$($d.code)" }
}

T "halt-shared-failure-not-advance" {
  $d = Get-PlanAdvance -Outcome "shared" -SharedFailure $true -HasNext $true
  if ($d.advance -or $d.code -ne "global_failure") { throw "code=$($d.code)" }
}

T "halt-last-platform" {
  $d = Get-PlanAdvance -Outcome "platform_complete" -HasNext $false
  if ($d.advance -or $d.code -ne "complete") { throw "code=$($d.code)" }
}

T "skip-consume-once" {
  $s = @{}
  $a = Test-PlanSkipConsume -SkipState $s -Platform "Telegram"
  $b = Test-PlanSkipConsume -SkipState $s -Platform "Telegram"
  if (-not $a -or $b) { throw "first=$a second=$b" }
}

T "stop-ack-immediate" {
  $r = Wait-StopAck -Probe { $true } -TimeoutSec 3 -PollMs 50
  if (-not $r.acked -or $r.timedOut -or $r.tries -ne 1) { throw "acked=$($r.acked) tries=$($r.tries)" }
}

T "stop-ack-timeout-reported" {
  $r = Wait-StopAck -Probe { $false } -TimeoutSec 1 -PollMs 100
  if ($r.acked -or -not $r.timedOut) { throw "acked=$($r.acked) timeout=$($r.timedOut)" }
  if ($r.waitedMs -lt 800) { throw "waited too little: $($r.waitedMs)" }
}

T "ledger-six-states-and-reconcile" {
  $l = New-CandidateLedger
  $null = Add-LedgerCandidate -Ledger $l -Key "g1" -Source "kw:cs2 trade" -Platform "Telegram"
  $null = Add-LedgerCandidate -Ledger $l -Key "g2" -Source "kw:cs2 trade" -Platform "Telegram"
  $null = Add-LedgerCandidate -Ledger $l -Key "g3" -Source "pool" -Platform "Telegram"
  $null = Add-LedgerCandidate -Ledger $l -Key "g4" -Source "pool" -Platform "Telegram"
  $null = Add-LedgerCandidate -Ledger $l -Key "g5" -Source "search" -Platform "Telegram"
  $null = Add-LedgerCandidate -Ledger $l -Key "g6" -Source "search" -Platform "Telegram"
  $null = Add-LedgerCandidate -Ledger $l -Key "g7" -Source "search" -Platform "Telegram"
  # g7 filtered (already recorded)
  Set-LedgerFilter -Ledger $l -Key "g7" -Reason "existing_in_sheet"
  # g1 joined, g2 pending, g3 existing, g4 failed, g5 dispatched no terminal
  [void](Set-LedgerDispatch -Ledger $l -Key "g1"); [void](Set-LedgerOutcome -Ledger $l -Key "g1" -Outcome "joined")
  [void](Set-LedgerDispatch -Ledger $l -Key "g2"); [void](Set-LedgerOutcome -Ledger $l -Key "g2" -Outcome "pending" -Reason "approval")
  [void](Set-LedgerDispatch -Ledger $l -Key "g3"); [void](Set-LedgerOutcome -Ledger $l -Key "g3" -Outcome "existing")
  [void](Set-LedgerDispatch -Ledger $l -Key "g4"); [void](Set-LedgerOutcome -Ledger $l -Key "g4" -Outcome "failed" -Reason "not_found")
  [void](Set-LedgerDispatch -Ledger $l -Key "g5"); [void](Set-LedgerOutcome -Ledger $l -Key "g5" -Outcome "skipped" -Reason "stop_not_executed")
  # g6 never dispatched (queue left at stop)
  $rec = Test-LedgerReconcile -Ledger $l
  $s = $rec.summary
  if ($s.total -ne 7) { throw "total=$($s.total)" }
  if ($s.filtered -ne 1) { throw "filtered=$($s.filtered)" }
  if ($s.joined -ne 1 -or $s.pending -ne 1 -or $s.existing -ne 1 -or $s.failed -ne 1 -or $s.skipped -ne 1) {
    throw "joined=$($s.joined) pending=$($s.pending) existing=$($s.existing) failed=$($s.failed) skipped=$($s.skipped)"
  }
  if ($s.dispatched -ne 5) { throw "dispatched=$($s.dispatched)" }
  if ($s.not_executed -ne 1) { throw "not_executed=$($s.not_executed)" }
  if (-not $rec.ok) { throw "reconcile not ok: terminal=$($rec.terminal) accounted=$($rec.accounted)" }
}

T "ledger-idempotent-terminal" {
  $l = New-CandidateLedger
  $null = Add-LedgerCandidate -Ledger $l -Key "x" -Source "s"
  [void](Set-LedgerDispatch -Ledger $l -Key "x")
  if (-not (Set-LedgerOutcome -Ledger $l -Key "x" -Outcome "joined")) { throw "first outcome rejected" }
  if (Set-LedgerOutcome -Ledger $l -Key "x" -Outcome "failed") { throw "second outcome accepted (should be idempotent)" }
  $s = Get-LedgerSummary $l
  if ($s.joined -ne 1 -or $s.failed -ne 0) { throw "joined=$($s.joined) failed=$($s.failed)" }
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
