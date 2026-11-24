# tests/offline/round_report.Tests.ps1
# 覆盖：每轮中文报告的计划顺序、各平台新增/已存在/未确认/失败、总结果与旧字段回退。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($got, $want, [string]$msg) { if ([string]$got -ne [string]$want) { throw ("$msg got=$got want=$want") } }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\round_report.ps1")

T "report-lines-plan-order" {
  $fb = New-PlatformResult -Platform "Facebook" -Result "完成" -Joined 2 -Existing 1 -Unconfirmed 1 -Failed 0
  $tg = New-PlatformResult -Platform "Telegram" -Result "部分完成（已停止新派发）" -Joined 0 -Existing 3 -Unconfirmed 0 -Failed 1 -Reason "未知回执"
  $r = New-RoundReport -Plan @("Facebook","Telegram") -Results @{ Facebook = $fb; Telegram = $tg } -StartedAt (Get-Date).AddMinutes(-7) -EndedAt (Get-Date) -Code "partial_complete" -LateCount 2 -RunId "r1"
  Assert-True (($r.lines[0] -like "本轮 *（7 分钟）")) "header"
  Assert-Eq $r.lines[1] "计划：Facebook → Telegram" "plan line"
  Assert-True (($r.lines[2] -like "Facebook：完成；新增 2，已存在 1，未确认 1，失败 0")) "fb line"
  Assert-True (($r.lines[3] -like "Telegram：部分完成*（未知回执）")) "tg line"
  Assert-True (($r.text -like "*迟到回执：2 条已隔离*")) "late line"
  Assert-True (($r.summary -like "总结果：部分完成（1 个未确认）*")) "summary"
}

T "report-already-not-new" {
  $fb = New-PlatformResult -Platform "Facebook" -Result "完成" -Joined 0 -Existing 4
  $r = New-RoundReport -Plan @("Facebook") -Results @{ Facebook = $fb } -Code "complete"
  Assert-True (($r.text -like "*新增 0，已存在 4*")) "counts"
  Assert-True (($r.text -like "*总结果：完成；新增 0*")) "verdict"
}

T "report-stopped-and-empty-reason" {
  $r = New-RoundReport -Plan @("Steam") -Results @{ Steam = (New-PlatformResult -Platform "Steam" -Result "已停止") } -Code "stopped" -StopReason "人工停止"
  Assert-True (($r.text -like "*Steam：已停止*")) "steam"
  Assert-True (($r.text -like "*总结果：人工停止；新增 0，已存在 0，未确认 0，失败 0（人工停止）*")) "stopped"
}

T "report-dedupes-plan" {
  $r = New-RoundReport -Plan @("Telegram","Telegram","Steam") -Results @{} -Code "complete"
  Assert-Eq (@($r.plan) -join ">") "Telegram>Steam" "dedupe"
}

T "report-old-field-fallback" {
  $old = [pscustomobject]@{ platform = "Reddit"; result = "完成"; joined = 1 }
  $line = Get-PlatformResultLine $old
  Assert-True (($line -like "Reddit：完成；新增 1，已存在 0，未确认 0，失败 0")) "fallback zeros"
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
