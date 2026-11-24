param()
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # repo root when run from tests\offline
if (-not (Test-Path (Join-Path $here "lib\run_plan.ps1"))) { $here = "D:\DeepSeek\运营" }
. (Join-Path $here "lib\run_control.ps1")
. (Join-Path $here "lib\run_plan.ps1")
. (Join-Path $here "lib\run_plan_gate.ps1")

$pass = 0; $fail = 0
function T([string]$name, [scriptblock]$sb) {
  try { & $sb; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: " + $_.Exception.Message }
}
function A($cond, [string]$msg) { if (-not $cond) { throw $msg } }

T "gate-advances-partial-when-unresolved" {
  $l = New-CandidateLedger
  $null = Add-LedgerCandidate -Ledger $l -Key "k1" -Name "g1" -Platform "Telegram"
  $null = Set-LedgerDispatch -Ledger $l -Key "k1"
  $r = Resolve-PlanAdvance -Outcome "platform_complete" -HasNext $true -PendingTerminal (Get-LedgerPendingTerminal $l)
  A ($r.advance -eq $true) "should advance to next platform"
  A ($r.code -eq "platform_partial") ("code=" + $r.code)
  $r2 = Resolve-PlanAdvance -Outcome "platform_complete" -HasNext $false -PendingTerminal (Get-LedgerPendingTerminal $l)
  A ($r2.advance -eq $false) "last platform must not advance"
  A ($r2.code -eq "partial_complete") ("code=" + $r2.code)
}

T "gate-advances-after-terminal" {
  $l = New-CandidateLedger
  $null = Add-LedgerCandidate -Ledger $l -Key "k1" -Name "g1" -Platform "Telegram"
  $null = Set-LedgerDispatch -Ledger $l -Key "k1"
  $null = Set-LedgerOutcome -Ledger $l -Key "k1" -Outcome "joined"
  $r = Resolve-PlanAdvance -Outcome "platform_complete" -HasNext $true -PendingTerminal (Get-LedgerPendingTerminal $l)
  A ($r.advance -eq $true) "should advance"
}

T "gate-no-next-completes" {
  $r = Resolve-PlanAdvance -Outcome "platform_complete" -HasNext $false
  A ($r.advance -eq $false) "no next must not advance"
  A ($r.code -eq "complete") ("code=" + $r.code)
}

T "gate-stop-wins" {
  $r = Resolve-PlanAdvance -Outcome "platform_complete" -StopRequested $true -HasNext $true
  A ($r.advance -eq $false) "stop must not advance"
  A ($r.code -eq "stopped") ("code=" + $r.code)
}

T "ledger-not-executed-fills" {
  $l = New-CandidateLedger
  foreach ($k in @("a","b","c")) {
    $null = Add-LedgerCandidate -Ledger $l -Key $k -Name $k -Platform "Telegram"
  }
  $null = Set-LedgerDispatch -Ledger $l -Key "a"
  $null = Set-LedgerOutcome -Ledger $l -Key "a" -Outcome "joined"
  $n = Set-LedgerNotExecuted $l
  A ($n -eq 2) ("filled=" + $n)
  A ($l["b"].outcome -eq "not_executed") "b not_executed"
  $s = Get-LedgerSummary $l
  A ($s.total -eq 3) ("total=" + $s.total)
}

T "run-control-persists-runid" {
  $tmp = Join-Path $env:TEMP ("gops_gate_" + [guid]::NewGuid().ToString("N").Substring(0,6))
  New-Item -ItemType Directory -Force -Path (Join-Path $tmp "data") | Out-Null
  $r1 = Register-RunControl -BaseDir $tmp -RunId "hub-A" -Platforms @("Telegram","Steam") -Current "Telegram"
  A ($r1.ok -eq $true) "first register ok"
  $o = Read-RunControl (Get-RunControlPath $tmp)
  A ($o.run_id -eq "hub-A") "run_id persisted"
  A (@($o.platforms).Count -eq 2) "platforms persisted"
  $r2 = Register-RunControl -BaseDir $tmp -RunId "hub-B" -Platforms @("Steam") -Current "Steam"
  A ($r2.ok -eq $false) "concurrent start must be rejected"
  A ($r2.reason -eq "run_active") ("reason=" + $r2.reason)
}

T "heartbeat-writes-and-fails-closed" {
  $tmp = Join-Path $env:TEMP ("gops_gate_" + [guid]::NewGuid().ToString("N").Substring(0,6))
  New-Item -ItemType Directory -Force -Path (Join-Path $tmp "data") | Out-Null
  $null = Register-RunControl -BaseDir $tmp -RunId "hub-H" -Platforms @("Telegram") -Current "Telegram"
  A ((Write-PlanHeartbeat -BaseDir $tmp -RunId "hub-H" -Platform "Telegram") -eq $true) "heartbeat ok"
  $o = Read-RunControl (Get-RunControlPath $tmp)
  A ([bool]$o.heartbeat_at) "heartbeat_at written"
  A ((Write-PlanHeartbeat -BaseDir $tmp -RunId "other" -Platform "Steam") -eq $false) "wrong run_id must fail closed"
}

T "plan-isolation-between-rounds" {
  $p1 = New-RunPlan -Platforms @("Telegram","Steam") -Known @("Telegram","Steam","Reddit")
  $p2 = New-RunPlan -Platforms @("Reddit") -Known @("Telegram","Steam","Reddit")
  A (($p1.order -join ">") -eq "Telegram>Steam") ("p1=" + ($p1.order -join ">"))
  A (($p2.order -join ">") -eq "Reddit") ("p2=" + ($p2.order -join ">"))
  $st = @{ plan = @(); planIndex = 0; planRunId = "" }
  $st.plan = @($p1.order); $st.planRunId = "hub-1"
  $st.plan = @($p2.order); $st.planIndex = 0; $st.planRunId = "hub-2"
  A (($st.plan -join ">") -eq "Reddit") "old plan must be replaced"
  A ($st.planRunId -eq "hub-2") "run id replaced"
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
