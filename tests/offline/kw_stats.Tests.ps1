# tests/offline/kw_stats.Tests.ps1
# 覆盖：v1 迁移、不同轮零结果 3 轮→24h→再 3 轮→7d、同轮去重、错误/未知不计、
# 命中唤醒、保护/手工淘汰/恢复、全休眠不回退、按平台隔离、策略覆盖。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($got, $want, [string]$msg) { if ([string]$got -ne [string]$want) { throw ("$msg got=$got want=$want") } }
function Assert-Near($got, $want, [double]$tol, [string]$msg) { if ([Math]::Abs([double]$got - [double]$want) -gt $tol) { throw ("$msg got=$got want~=$want") } }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\kw_stats.ps1")

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kw_stats_test_" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $tmp "data") -Force
$t0 = [datetime]"2026-11-26T10:00:00"

try {
  T "v1-migration" {
    $v1 = '{"Telegram|legacy term":{"rounds":2,"hits":1,"misses":1,"last":"2026-11-25T09:00:00"}}'
    [IO.File]::WriteAllText((Get-KwStatsPath $tmp), $v1, (New-Object Text.UTF8Encoding($false)))
    $st = Read-KwStats $tmp
    $e = Get-KwEntry $st "Telegram" "legacy term" $false
    Assert-True ($null -ne $e) "entry"
    Assert-Eq $e["rounds"] 2 "rounds"
    Assert-Eq $e["hits"] 1 "hits"
    Assert-Eq $e["misses"] 1 "misses"
  }

  T "three-distinct-zero-rounds-sleep-24h" {
    $a = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r1" "" $t0
    $b = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r2" "" $t0.AddMinutes(1)
    Assert-True (-not $a.slept -and -not $b.slept) "first two must not sleep"
    $c = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r3" "" $t0.AddMinutes(2)
    Assert-True $c.slept "third sleeps"
    $e = Get-KwEntry (Read-KwStats $tmp) "Telegram" "cs2 trade" $false
    Assert-Eq $e["sleep_level"] 1 "level"
    Assert-Eq $e["rounds"] 3 "rounds"
    Assert-Eq $e["misses"] 3 "misses"
    Assert-Eq $e["consecutive_zero_rounds"] 0 "streak reset after sleep"
    $left = Get-KwSleepRemainingHours $e $t0.AddMinutes(2)
    Assert-Near $left 24 0.1 "24h window"
    Assert-Eq (Get-KwEffectiveState $e $t0.AddMinutes(2)) "sleep" "state"
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("cs2 trade") $t0.AddMinutes(2)).Count) 0 "all asleep yields empty, no fallback"
    $dup = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r3" "" $t0.AddMinutes(3)
    Assert-True $dup.duplicate "same round duplicate"
    Assert-True (-not $dup.counted) "same round not counted"
    $e2 = Get-KwEntry (Read-KwStats $tmp) "Telegram" "cs2 trade" $false
    Assert-Eq $e2["rounds"] 3 "duplicate did not change rounds"
  }

  T "error-and-unknown-not-counted" {
    for ($i = 1; $i -le 5; $i++) {
      $x = Register-KwRoundResult $tmp "Telegram" "error term" 0 0 $true ("e" + $i) "extension error" $t0.AddMinutes($i)
      Assert-True (-not $x.counted) "failed not counted"
    }
    $x = Register-KwRoundResult $tmp "Telegram" "error term" $null 0 $false "u1" "" $t0.AddMinutes(6)
    Assert-True (-not $x.counted) "unknown not counted"
    $e = Get-KwEntry (Read-KwStats $tmp) "Telegram" "error term" $false
    Assert-Eq $e["rounds"] 0 "errors do not add rounds"
    Assert-Eq $e["errors"] 6 "errors recorded"
    Assert-Eq $e["misses"] 0 "errors do not add misses"
    Assert-True ($null -eq $e["sleep_until"]) "errors do not sleep"
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("error term") $t0.AddMinutes(7)).Count) 1 "still active"
  }

  T "escalation-to-7d-after-24h" {
    $t1 = $t0.AddHours(25)
    $null = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r4" "" $t1
    $null = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r5" "" $t1.AddMinutes(1)
    $c = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 0 0 $false "r6" "" $t1.AddMinutes(2)
    Assert-True $c.slept "second strike sleeps"
    $e = Get-KwEntry (Read-KwStats $tmp) "Telegram" "cs2 trade" $false
    Assert-Eq $e["sleep_level"] 2 "level 2"
    Assert-Eq $e["strikes"] 2 "strikes"
    $left = Get-KwSleepRemainingHours $e $t1.AddMinutes(2)
    Assert-Near $left 168 0.1 "168h window"
  }

  T "hit-wakes-auto-sleep" {
    $t2 = $t0.AddHours(26)
    $h = Register-KwRoundResult $tmp "Telegram" "cs2 trade" 4 2 $false "r7" "" $t2
    Assert-True $h.counted "hit counted"
    $e = Get-KwEntry (Read-KwStats $tmp) "Telegram" "cs2 trade" $false
    Assert-Eq (Get-KwEffectiveState $e $t2) "active" "active after hit"
    Assert-True ($null -eq $e["sleep_until"]) "sleep cleared"
    Assert-Eq $e["sleep_level"] 0 "level reset"
    Assert-Eq $e["hits"] 1 "hits"
    Assert-Eq $e["consecutive_zero_rounds"] 0 "streak reset"
  }

  T "protected-prune-recover" {
    $null = Set-KwKeywordState $tmp "Telegram" "protected term" "protect" 0 $t0
    for ($i = 1; $i -le 3; $i++) { $null = Register-KwRoundResult $tmp "Telegram" "protected term" 0 0 $false ("p" + $i) "" $t0.AddMinutes($i) }
    $e = Get-KwEntry (Read-KwStats $tmp) "Telegram" "protected term" $false
    Assert-Eq (Get-KwEffectiveState $e $t0.AddMinutes(4)) "protected" "protected stays"
    Assert-True ($null -eq $e["sleep_until"]) "protected not slept"
    $null = Set-KwKeywordState $tmp "Telegram" "protected term" "prune" 0 $t0.AddMinutes(5)
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("protected term") $t0.AddMinutes(6)).Count) 0 "pruned excluded"
    $null = Set-KwKeywordState $tmp "Telegram" "protected term" "recover" 0 $t0.AddMinutes(7)
    Assert-Eq (Get-KwEffectiveState (Get-KwEntry (Read-KwStats $tmp) "Telegram" "protected term" $false) $t0.AddMinutes(8)) "active" "recovered"
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("protected term") $t0.AddMinutes(8)).Count) 1 "recovered ranked"
    $null = Set-KwKeywordState $tmp "Telegram" "protected term" "sleep" 2 $t0.AddMinutes(9)
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("protected term") $t0.AddMinutes(10)).Count) 0 "manual sleep excluded"
  }

  T "all-asleep-no-fallback-and-platform-isolation" {
    $null = Register-KwRoundResult $tmp "Telegram" "tg one" 0 0 $false "t1" "" $t0
    $null = Register-KwRoundResult $tmp "Telegram" "tg one" 0 0 $false "t2" "" $t0.AddMinutes(1)
    $null = Register-KwRoundResult $tmp "Telegram" "tg one" 0 0 $false "t3" "" $t0.AddMinutes(2)
    $null = Register-KwRoundResult $tmp "Facebook" "tg one" 0 0 $false "f1" "" $t0
    $null = Register-KwRoundResult $tmp "Facebook" "tg one" 0 0 $false "f2" "" $t0.AddMinutes(1)
    $null = Register-KwRoundResult $tmp "Facebook" "tg one" 0 0 $false "f3" "" $t0.AddMinutes(2)
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("tg one") $t0.AddMinutes(3)).Count) 0 "Telegram empty"
    Assert-Eq (@(Get-KwRanked $tmp "Facebook" @("tg one") $t0.AddMinutes(3)).Count) 0 "Facebook empty too"
    $null = Register-KwRoundResult $tmp "Facebook" "fb live" 1 1 $false "f4" "" $t0.AddMinutes(4)
    Assert-Eq (@(Get-KwRanked $tmp "Telegram" @("fb live") $t0.AddMinutes(5)).Count) 1 "platform isolation"
  }

  T "policy-config-is-honored" {
    $cfg = [pscustomobject]@{ kw_evolve = [pscustomobject]@{ zero_rounds = 5; first_sleep_hours = 2 } }
    $null = Register-KwRoundResult $tmp "Steam" "policy term" 0 0 $false "s1" "" $t0 $cfg
    $null = Register-KwRoundResult $tmp "Steam" "policy term" 0 0 $false "s2" "" $t0.AddMinutes(1) $cfg
    $null = Register-KwRoundResult $tmp "Steam" "policy term" 0 0 $false "s3" "" $t0.AddMinutes(2) $cfg
    $e = Get-KwEntry (Read-KwStats $tmp) "Steam" "policy term" $false
    Assert-True ($null -eq $e["sleep_until"]) "3 zeros not enough when policy=5"
    $null = Register-KwRoundResult $tmp "Steam" "policy term" 0 0 $false "s4" "" $t0.AddMinutes(3) $cfg
    $c = Register-KwRoundResult $tmp "Steam" "policy term" 0 0 $false "s5" "" $t0.AddMinutes(4) $cfg
    Assert-True $c.slept "5th sleeps"
    $e2 = Get-KwEntry (Read-KwStats $tmp) "Steam" "policy term" $false
    $left = Get-KwSleepRemainingHours $e2 $t0.AddMinutes(4)
    Assert-Near $left 2 0.1 "configured 2h"
  }

  T "status-summary" {
    $st = Get-KwStatus $tmp "Telegram" $t0.AddHours(2)
    Assert-True ($st.summary.total -ge 3) "total"
    Assert-True ($st.summary.sleep -ge 1) "sleep count"
    Assert-True ($st.summary.protected -ge 0) "protected count"
    Assert-True (@($st.keywords).Count -ge 3) "rows"
  }
}
finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
