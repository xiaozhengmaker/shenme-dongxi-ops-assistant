# tests/offline/hub_dispatch.Tests.ps1
# 覆盖：不可变派发身份、按 task id 解析回执、迟到/重复隔离、already 不计新增、
#       unknown 记未确认并停当前平台、平台统计与报告。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($got, $want, [string]$msg) { if ([string]$got -ne [string]$want) { throw ("$msg got=$got want=$want") } }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\run_plan.ps1")
. (Join-Path $root "lib\run_plan_gate.ps1")
. (Join-Path $root "lib\round_report.ps1")
. (Join-Path $root "lib\hub_dispatch.ps1")

$item1 = [pscustomobject]@{ id = "i1"; u = "u1"; t = "Alice"; src = "fb" }
$item2 = [pscustomobject]@{ id = "i2"; u = "u2"; t = "Bob"; src = "fb" }

T "init-round-plan-and-stats" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook","Telegram") -External $false
  Assert-Eq $s.planRunId "run-1" "run_id"
  Assert-Eq (@($s.plan) -join ">") "Facebook>Telegram" "plan order"
  Assert-True $s.platformStats.ContainsKey("Facebook") "fb stat"
  Assert-Eq $s.platformStats["Facebook"].result "未运行" "fb init"
  Assert-Eq $s.externalRun $false "external"
}

T "dispatch-immutable-identity" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook") -External $false
  $d = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  Assert-True ($null -ne $d) "dispatch"
  Assert-Eq $d.ledger_key "i1|u1|Alice" "ledger key"
  Assert-Eq $d.run_id "run-1" "run id"
  Assert-Eq $d.platform "Facebook" "platform"
  Assert-Eq $s.pending.id "t1" "pending"
  Assert-True ([bool]$s.ledger["i1|u1|Alice"].dispatched) "ledger dispatched"
  $again = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t2"
  Assert-True ($null -eq $again) "no re-dispatch"
}

T "receipt-joined-applied" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook") -External $false
  $d = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  $r = Resolve-HubJoinReceipt -State $s -CurrentPlatform "Facebook" -TaskId "t1" -Value "joined"
  Assert-Eq $r.status "applied" "status"
  Assert-Eq $r.outcome "joined" "outcome"
  $before = @{ joined = 0; existing = 0; local = 0; failed = 0; unconfirmed = 0; skipped = 0 }
  $s.joined = 1
  $null = Complete-HubJoinReceipt -State $s -Dispatch $d -Outcome $r.outcome -Before $before
  Assert-True ($null -eq $s.pending) "pending cleared"
  Assert-True ($null -eq $s.joinInflight) "inflight cleared"
  Assert-Eq $s.platformStats["Facebook"].joined 1 "platform joined"
}

T "receipt-already-is-not-new" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook") -External $false
  $d = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  $r = Resolve-HubJoinReceipt -State $s -CurrentPlatform "Facebook" -TaskId "t1" -Value "already"
  Assert-Eq $r.outcome "existing" "outcome"
  $c = Get-HubReceiptCounts -Value "already"
  Assert-Eq $c.joined 0 "already joined"
  Assert-Eq $c.existing 1 "already existing"
  $before = @{ joined = 0; existing = 0; local = 0; failed = 0; unconfirmed = 0; skipped = 0 }
  $s.existing = 1
  $null = Complete-HubJoinReceipt -State $s -Dispatch $d -Outcome $r.outcome -Before $before
  Assert-Eq $s.platformStats["Facebook"].existing 1 "stat existing"
  Assert-Eq $s.platformStats["Facebook"].joined 0 "stat joined"
}

T "receipt-unknown-stops-platform" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook","Telegram") -External $false
  $d = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  $r = Resolve-HubJoinReceipt -State $s -CurrentPlatform "Facebook" -TaskId "t1" -Value "unknown"
  Assert-Eq $r.status "applied" "status"
  Assert-Eq $r.outcome "unconfirmed" "outcome"
  Assert-True ([bool]$r.abort) "abort"
  $before = @{ joined = 0; existing = 0; local = 0; failed = 0; unconfirmed = 0; skipped = 0 }
  $s.unconfirmed = 1
  $null = Complete-HubJoinReceipt -State $s -Dispatch $d -Outcome "unconfirmed" -Before $before
  Assert-Eq $s.platformStats["Facebook"].unconfirmed 1 "stat unconfirmed"
}

T "late-receipt-isolated-after-platform-advance" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook","Telegram") -External $false
  $d1 = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  $s.planIndex = 1
  $d2 = New-HubJoinDispatch -State $s -Item $item2 -Platform "Telegram" -TaskId "t2"
  $r = Resolve-HubJoinReceipt -State $s -CurrentPlatform "Telegram" -TaskId "t1" -Value "joined"
  Assert-Eq $r.status "late" "status"
  Assert-Eq $r.reason "late_platform" "reason"
  Assert-Eq $s.pending.id "t2" "pending unchanged"
  Assert-Eq $s.joinInflight.id "t2" "inflight unchanged"
}

T "duplicate-receipt-isolated" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook") -External $false
  $d = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  $null = Complete-HubJoinReceipt -State $s -Dispatch $d -Outcome "joined" -Before $null
  $r = Resolve-HubJoinReceipt -State $s -CurrentPlatform "Facebook" -TaskId "t1" -Value "joined"
  Assert-Eq $r.status "duplicate" "status"
  Assert-Eq @($s.lateReceipts).Count 1 "late count"
}

T "pending-terminal-counted-in-report" {
  $s = @{}
  $null = Initialize-HubRound -State $s -RunId "run-1" -Platforms @("Facebook") -External $false
  $null = New-HubJoinDispatch -State $s -Item $item1 -Platform "Facebook" -TaskId "t1"
  $null = Complete-HubPlatform -State $s -Platform "Facebook" -Result "部分完成" -Ledger $s.ledger
  Assert-Eq $s.platformStats["Facebook"].unconfirmed 1 "pending unconfirmed"
  $rep = Get-HubRoundReport -State $s -Code "partial_complete"
  Assert-True (($rep.text -like "*计划：Facebook*")) "plan line"
  Assert-True (($rep.text -like "*未确认 1*")) "unconfirmed line"
  Assert-True (($rep.text -like "*总结果：部分完成*")) "verdict"
}

T "advance-platform-aborted" {
  $d = Resolve-PlanAdvance -Outcome "platform_complete" -PlatformAborted $true -HasNext $true
  Assert-True ([bool]$d.advance) "advance"
  Assert-Eq $d.code "platform_partial" "code"
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
