$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
. (Join-Path $here "..\..\lib\round_engine.ps1")
$script:pass = 0; $script:fail = 0
function Chk($cond, $name) { if ($cond) { $script:pass++; "PASS $name" } else { $script:fail++; "FAIL $name" } }
function NewWD([string]$tag) { $w = Join-Path $env:TEMP ("gops_it_" + $tag + "_" + (Get-Date -Format "HHmmssfff")); New-Item -ItemType Directory -Force -Path (Join-Path $w "data") | Out-Null; return $w }
function RC($w) { Get-Content (Join-Path $w "data\run_control.json") -Raw | ConvertFrom-Json }

$w1 = NewWD "multi"
$r1 = @{
  Telegram = { param($p,$d) @{ result="complete"; items=@(@{key="tg1";name="A";dispatched=$true;outcome="joined"},@{key="tg2";name="B";dispatched=$true;outcome="joined"}) } }.GetNewClosure()
  Steam    = { param($p,$d) @{ result="complete"; items=@(@{key="st1";name="C";dispatched=$true;outcome="existing"}) } }.GetNewClosure()
}
$s1 = Invoke-RoundRun -WorkDir $w1 -Plan @("Telegram","Steam") -RunId "run-1" -Entry manual -Runners $r1
Chk ($s1.state -eq "complete") "multi: state complete"
Chk (@($s1.order).Count -eq 2 -and $s1.order[0].platform -eq "Telegram" -and $s1.order[1].platform -eq "Steam") "multi: 顺序 Telegram>Steam"
Chk ($s1.plan[0] -eq "Telegram" -and $s1.plan[1] -eq "Steam") "multi: 计划冻结顺序"
Chk ($s1.summary.joined -eq 2 -and $s1.summary.existing -eq 1) "multi: 台账 joined=2 existing=1"
Chk ((RC $w1).run_id -eq "run-1") "multi: run_id 持久化到 run_control"

$w2 = NewWD "skip"
Set-Content (Join-Path $w2 "data\ctl_skip") "Telegram" -Encoding UTF8
$r2 = @{
  Telegram = { param($p,$d) @{ result="complete"; items=@(@{key="tgx";dispatched=$true;outcome="joined"}) } }.GetNewClosure()
  Steam    = { param($p,$d) @{ result="complete"; items=@(@{key="stx";dispatched=$true;outcome="joined"}) } }.GetNewClosure()
}
$s2 = Invoke-RoundRun -WorkDir $w2 -Plan @("Telegram","Steam") -RunId "run-2" -Runners $r2
Chk ($s2.order[0].result -eq "skip_operator" -and @($s2.order).Count -eq 2) "skip: 只跳当前平台一次并顺延"
Chk (-not (Test-Path (Join-Path $w2 "data\ctl_skip"))) "skip: 标记被消费"
Chk ($s2.state -eq "complete") "skip: 后续平台完成"

$w3 = NewWD "stop"
$r3 = @{ Telegram = { param($p,$d) Set-Content (Join-Path $d "ctl_stop") "1"; @{ result="complete"; items=@(@{key="t1";dispatched=$true;outcome="joined"}) } }.GetNewClosure(); Steam = { param($p,$d) @{ result="complete" } }.GetNewClosure() }
$s3 = Invoke-RoundRun -WorkDir $w3 -Plan @("Telegram","Steam") -RunId "run-3" -Runners $r3
Chk ($s3.state -eq "stopped") "stop: 整轮停止"
Chk (@($s3.order).Count -eq 1) "stop: 不启动下一平台"

$w4 = NewWD "emerg"
$r4 = @{ Telegram = { param($p,$d) Set-Content (Join-Path $d "ctl_emergency") "1"; @{ result="complete" } }.GetNewClosure(); Steam = { param($p,$d) @{ result="complete" } }.GetNewClosure() }
$s4 = Invoke-RoundRun -WorkDir $w4 -Plan @("Telegram","Steam") -RunId "run-4" -Runners $r4
Chk ($s4.state -eq "emergency_stopped") "emergency: 全局急停停止"

$w5 = NewWD "shared"
$r5 = @{ Telegram = { param($p,$d) @{ result="platform_failure"; shared=$true; items=@(@{key="f1";dispatched=$true;outcome="failed"}) } }.GetNewClosure(); Steam = { param($p,$d) @{ result="complete" } }.GetNewClosure() }
$s5 = Invoke-RoundRun -WorkDir $w5 -Plan @("Telegram","Steam") -RunId "run-5" -Runners $r5
Chk ($s5.state -eq "global_failure") "shared: 全局故障不顺延"
Chk (@($s5.order).Count -eq 1) "shared: 第二平台未执行"

$w6 = NewWD "inflight"
$r6 = @{ Telegram = { param($p,$d) @{ result="complete"; inflight=$true; items=@(@{key="i1";dispatched=$true}) } }.GetNewClosure(); Steam = { param($p,$d) @{ result="complete" } }.GetNewClosure() }
$s6 = Invoke-RoundRun -WorkDir $w6 -Plan @("Telegram","Steam") -RunId "run-6" -Runners $r6 -AckTimeoutSec 1 -AckPollMs 50
Chk ($s6.state -eq "partial_complete") "inflight: 未确认只停当前平台，整轮部分完成"
Chk ($s6.ledger["i1"].outcome -eq "unconfirmed") "inflight: 台账记 unconfirmed 而非 not_executed"
Chk ($s6.summary.pending -eq 1) "inflight: summary.pending=1"
Chk ($s6.order[0].result -eq "platform_partial") "inflight: 当前平台标记 platform_partial"
Chk (@($s6.order).Count -eq 2) "inflight: 顺延到下一平台"

$w7 = NewWD "ack"
$r7 = @{ Telegram = { param($p,$d) Set-Content (Join-Path $d "ack_Telegram") "1"; '{"i1":"joined"}' | Set-Content (Join-Path $d "resolve_Telegram.json"); @{ result="complete"; inflight=$true; items=@(@{key="i1";dispatched=$true}) } }.GetNewClosure(); Steam = { param($p,$d) @{ result="complete"; items=@(@{key="s1";dispatched=$true;outcome="joined"}) } }.GetNewClosure() }
$s7 = Invoke-RoundRun -WorkDir $w7 -Plan @("Telegram","Steam") -RunId "run-7" -Runners $r7 -AckTimeoutSec 2 -AckPollMs 50
Chk ($s7.state -eq "complete") "ack: 收到确认后顺延完成"
Chk ($s7.summary.joined -eq 2) "ack: 回写终态 joined=2"

$w8 = NewWD "partial"
$r8 = @{ Telegram = { param($p,$d) @{ result="platform_failure"; items=@(@{key="f1";dispatched=$true;outcome="failed"}) } }.GetNewClosure(); Steam = { param($p,$d) @{ result="complete"; items=@(@{key="s1";dispatched=$true;outcome="joined"}) } }.GetNewClosure() }
$s8 = Invoke-RoundRun -WorkDir $w8 -Plan @("Telegram","Steam") -RunId "run-8" -Runners $r8
Chk ($s8.state -eq "complete") "partial: 平台局部失败仍顺延"
Chk ($s8.summary.failed -eq 1 -and $s8.summary.joined -eq 1) "partial: 台账 failed=1 joined=1"

$w9 = NewWD "daily"
$r9 = @{ Telegram = { param($p,$d) @{ result="complete" } }.GetNewClosure() }
$s9 = Invoke-RoundRun -WorkDir $w9 -Plan @("Telegram") -RunId "run-9" -Entry daily -Runners $r9
Chk ((RC $w9).entry -eq "daily") "entry: daily 写入 run_control"
Chk ($s9.state -eq "complete") "entry: daily 正常完成"

$cliWD = NewWD "cli"
$cliOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "..\..\tools\round_run.ps1") -WorkDir $cliWD -Plan Telegram -RunId "run-cli" 2>&1 | Out-String
Chk ($cliOut -match "platform_failure") "cli: 无 runner 时 fail-closed 为 platform_failure"
Chk ((RC $cliWD).run_id -eq "run-cli") "cli: 真实入口写 run_control"

"RESULT pass=$script:pass fail=$script:fail"
if ($script:fail -gt 0) { exit 1 }