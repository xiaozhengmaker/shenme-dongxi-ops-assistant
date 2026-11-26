# tests/offline/kw_trend.Tests.ps1
# 覆盖：有日期来源信号聚合、无 key/无信号/超预算显式状态、最多 5 条、来源校验、
# 人工应用与按批回滚、冲突检测、AI 错误/非法 JSON、去重与 not_due。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($got, $want, [string]$msg) { if ([string]$got -ne [string]$want) { throw ("$msg got=$got want=$want") } }
function Assert-Contains([string]$hay, [string]$needle, [string]$msg) { if ($hay.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw ("$msg missing=$needle hay=$hay") } }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\kw_stats.ps1")
. (Join-Path $root "lib\kw_trend.ps1")

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kw_trend_test_" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $tmp "data") -Force
$cfgPath = Join-Path $tmp "config.json"
$now = [datetime]"2026-11-26T12:00:00"

function New-TestConfig([double]$budget = 10.0, [string]$key = "test-key-not-real", [int]$maxSug = 5) {
  return [pscustomobject]@{
    strategy = [pscustomobject]@{
      Telegram = [pscustomobject]@{ discovery = [pscustomobject]@{ keywords = @("existing term") } }
      Facebook = [pscustomobject]@{ discovery = [pscustomobject]@{ keywords = @() } }
    }
    keywordPool = @()
    ai = [pscustomobject]@{ provider = "deepseek"; base_url = "https://api.deepseek.com"; model = "deepseek-chat"; api_key = $key; timeout = 30 }
    kw_evolve = [pscustomobject]@{ enabled = $true; ai_enabled = $true; zero_rounds = 3; first_sleep_hours = 24; second_sleep_hours = 168; ai_window_days = 14; ai_max_suggestions = $maxSug; ai_weekly_budget_cny = $budget }
  }
}
function Save-TestConfig($cfg) {
  [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($false)))
}
function New-LedgerLine([string]$ts, [string]$platform, [string]$sid, [string]$q, [int]$raw, [int]$eligible, [int]$joined) {
  return (@{ ts = $ts; platform = $platform; source_id = $sid; query = $q; raw = $raw; eligible = $eligible; joined = $joined } | ConvertTo-Json -Compress)
}
function Add-TestSignals {
  $lines = @()
  $lines += New-LedgerLine "2026-11-25T10:00:00" "Telegram" "src-001" "new trading term" 10 5 1
  $lines += New-LedgerLine "2026-11-25T10:05:00" "Telegram" "src-002" "new trading term" 8 4 1
  $lines += New-LedgerLine "2026-11-25T11:00:00" "Telegram" "src-003" "sleepy term" 6 2 0
  $lines += New-LedgerLine "2026-11-25T11:10:00" "Telegram" "src-004" "weighty term" 6 3 1
  $lines += New-LedgerLine "2026-11-25T12:00:00" "Facebook" "src-005" "fb term" 4 2 0
  # 含个人信息的行必须被过滤，不能进入 prompt/signals
  $lines += New-LedgerLine "2026-11-25T12:30:00" "Telegram" "src-006" "user@example.com" 5 1 0
  [IO.File]::WriteAllLines((Join-Path $tmp "data\source_ledger.jsonl"), $lines, (New-Object Text.UTF8Encoding($false)))
}
function New-FakeInvoker([string]$jsonText) {
  return { param($ai, $system, $user) [pscustomobject]@{ ok = $true; text = $jsonText; usage = [pscustomobject]@{ prompt_tokens = 120; completion_tokens = 80 } } }.GetNewClosure()
}
function New-SignalIds([string]$query) {
  $sigs = @(Get-KwLedgerSignals $tmp 14 60 $now)
  foreach ($s in $sigs) { if (([string]$s.query) -eq $query) { return @($s.sources) } }
  return @()
}
function New-Suggestion([string]$action, [string]$platform, [string]$keyword, [string[]]$ids) {
  return [ordered]@{ action = $action; platform = $platform; keyword = $keyword; reason = "test evidence"; confidence = 0.8; source_ids = @($ids) }
}
function New-JsonSuggestions($items) { return ([ordered]@{ suggestions = @($items) } | ConvertTo-Json -Depth 8) }

try {
  $cfg = New-TestConfig
  Save-TestConfig $cfg
  $null = Set-KwKeywordState $tmp "Telegram" "sleepy term" "sleep" 24 $now
  $null = Register-KwRoundResult $tmp "Telegram" "weighty term" 2 1 $false "w1" "" $now.AddDays(-1)
  $null = Set-KwKeywordState $tmp "Telegram" "protected term" "protect" 0 $now.AddDays(-1)
  Add-TestSignals

  T "safe-keyword-filter" {
    Assert-True (Test-KwSafeKeyword "cs2 trade") "normal keyword"
    Assert-True (-not (Test-KwSafeKeyword "user@example.com")) "email rejected"
    Assert-True (-not (Test-KwSafeKeyword "https://example.com/x")) "url rejected"
    Assert-True (-not (Test-KwSafeKeyword "13800138000")) "phone rejected"
    Assert-True (-not (Test-KwSafeKeyword "a")) "too short rejected"
  }

  T "ledger-signals-need-date-and-source" {
    $sigs = @(Get-KwLedgerSignals $tmp 14 60 $now)
    Assert-True ($sigs.Count -ge 3) "signals count"
    $names = @($sigs | ForEach-Object { [string]$_.query })
    Assert-True ($names -contains "new trading term") "aggregated query"
    Assert-True ($names -notcontains "user@example.com") "unsafe query filtered"
    $nt = @($sigs | Where-Object { $_.query -eq "new trading term" })
    Assert-Eq $nt.Count 1 "aggregated one row"
    Assert-Eq $nt[0].rounds 2 "two dated rows aggregated"
    Assert-Eq $nt[0].source_count 2 "two sources"
  }

  T "ledger-source-id-not-sent-to-ai" {
    $sigs = @(Get-KwLedgerSignals $tmp 14 60 $now)
    $p = Get-KwTrendPrompt $sigs @() (Get-KwPolicy (New-TestConfig))
    Assert-True (-not ($p.user -match "src-00[1-6]")) "raw ledger source id not in prompt"
    Assert-Contains $p.user "ledger:" "opaque ledger key in prompt"
  }

  T "no-key-status" {
    $c = New-TestConfig 10.0 ""
    $r = New-KwTrendSuggestions $tmp $cfgPath $c $now -Force
    Assert-True (-not $r.ok) "not ok"
    Assert-Eq $r.status "no_key" "status"
    Assert-True ($r.masked -eq "" -or $null -eq $r.masked) "no masked key when absent"
    $st = Read-KwTrendState $tmp
    Assert-Eq $st["last_status"] "no_key" "no_key persisted for UI"
  }

  T "no-signals-status" {
    $empty = Join-Path $tmp "nosignals"
    $null = New-Item -ItemType Directory -Path (Join-Path $empty "data") -Force
    $c = New-TestConfig
    $r = New-KwTrendSuggestions $empty $null $c $now -Force
    Assert-True (-not $r.ok) "not ok"
    Assert-Eq $r.status "no_signals" "status"
    $st = Read-KwTrendState $empty
    Assert-Eq $st["last_status"] "no_signals" "no_signals persisted for UI"
  }

  T "budget-exceeded-status" {
    $c = New-TestConfig 0.000001
    $r = New-KwTrendSuggestions $tmp $cfgPath $c $now -Force
    Assert-True (-not $r.ok) "not ok"
    Assert-Eq $r.status "budget_exceeded" "status"
    Assert-True ($null -ne $r.budget) "budget detail"
    $st = Read-KwTrendState $tmp
    Assert-Eq $st["last_status"] "budget_exceeded" "budget status persisted for UI"
  }

  T "ai-error-and-invalid-json" {
    $ids = @(New-SignalIds "new trading term")
    $c = New-TestConfig
    $bad = { param($ai, $system, $user) [pscustomobject]@{ ok = $false; text = ""; error = "upstream 500" } }.GetNewClosure()
    $r = New-KwTrendSuggestions $tmp $cfgPath $c $now -Force -AiInvoker $bad -NoWrite
    Assert-True (-not $r.ok) "ai_error not ok"
    Assert-Eq $r.status "ai_error" "ai_error status"
    $inv = New-FakeInvoker "this is not json"
    $r2 = New-KwTrendSuggestions $tmp $cfgPath $c $now -Force -AiInvoker $inv -NoWrite
    Assert-True (-not $r2.ok) "invalid not ok"
    Assert-Eq $r2.status "ai_invalid" "invalid status"
  }

  T "generate-valid-suggestions-and-source-check" {
    $a = New-SignalIds "new trading term"
    $b = New-SignalIds "sleepy term"
    $d = New-SignalIds "weighty term"
    $f = New-SignalIds "fb term"
    $items = @(
      (New-Suggestion "add" "Telegram" "brand new term" $a),
      (New-Suggestion "revive" "Telegram" "sleepy term" $b),
      (New-Suggestion "downweight" "Telegram" "weighty term" $d),
      (New-Suggestion "add" "Facebook" "fb term two" $f),
      (New-Suggestion "add" "Telegram" "bad source term" @("not-a-real-source")),
      (New-Suggestion "add" "Telegram" "user@example.com" $a)
    )
    $inv = New-FakeInvoker (New-JsonSuggestions $items)
    $r = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig) $now -Force -AiInvoker $inv -NoWrite
    Assert-True $r.ok "ok"
    Assert-Eq $r.status "suggested" "status"
    Assert-Eq @($r.suggestions).Count 4 "4 valid"
    Assert-True (@($r.rejected | Where-Object { $_.reason -eq "no_valid_source" }).Count -ge 1) "bad source rejected"
    Assert-True (@($r.rejected | Where-Object { $_.reason -eq "unsafe_keyword" }).Count -ge 1) "unsafe keyword rejected"
    $first = @($r.suggestions)[0]
    Assert-Eq $first.status "pending" "pending"
    Assert-True (@($first.sources).Count -ge 1) "source details kept"
    Assert-True (@($first.source_ids).Count -ge 1) "source ids kept"
    Assert-True (-not ([string]$r | Select-String -Pattern "api_key" -Quiet)) "no api key in result"
  }

  T "max-five-hard-limit" {
    $ids = @(New-SignalIds "new trading term")
    $items = @()
    for ($i = 1; $i -le 9; $i++) { $items += (New-Suggestion "add" "Telegram" ("limit term " + $i) $ids) }
    $inv = New-FakeInvoker (New-JsonSuggestions $items)
    $r = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig 10.0 "test-key-not-real" 9) $now -Force -AiInvoker $inv -NoWrite
    Assert-Eq @($r.suggestions).Count 5 "policy clamps to 5"
  }

  T "apply-and-rollback-batch" {
    $a = New-SignalIds "new trading term"
    $b = New-SignalIds "sleepy term"
    $d = New-SignalIds "weighty term"
    $items = @(
      (New-Suggestion "add" "Telegram" "applied new term" $a),
      (New-Suggestion "revive" "Telegram" "sleepy term" $b),
      (New-Suggestion "downweight" "Telegram" "weighty term" $d)
    )
    $inv = New-FakeInvoker (New-JsonSuggestions $items)
    $r = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig) $now -Force -AiInvoker $inv
    Assert-True $r.ok "generated"
    Assert-Eq $r.status "suggested" "suggested"
    $batchId = [string]$r.batch.id
    Assert-True ($batchId -like "kwt-*") "batch id"
    $ap = Apply-KwTrendBatch $tmp $cfgPath $batchId $now
    Assert-True $ap.ok "apply ok"
    Assert-Eq $ap.status "applied" "apply status"

    $cfg2 = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($cfg2.strategy.Telegram.discovery.keywords) -contains "applied new term") "add applied"
    $stats2 = Read-KwStats $tmp
    $sleepy = Get-KwEntry $stats2 "Telegram" "sleepy term" $false
    Assert-Eq (Get-KwEffectiveState $sleepy $now) "active" "revived active"
    $weighty = Get-KwEntry $stats2 "Telegram" "weighty term" $false
    Assert-Eq $weighty["weight"] 0.5 "downweighted"

    $ap2 = Apply-KwTrendBatch $tmp $cfgPath $batchId $now
    Assert-True (-not $ap2.ok) "apply is idempotent-guarded"
    Assert-Eq $ap2.error "batch_not_suggested" "second apply rejected"

    $rb = Rollback-KwTrendBatch $tmp $cfgPath $batchId $now
    Assert-True $rb.ok "rollback ok"
    Assert-Eq $rb.status "rolled_back" "rollback status"
    $cfg3 = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($cfg3.strategy.Telegram.discovery.keywords) -notcontains "applied new term") "add removed"
    $stats3 = Read-KwStats $tmp
    $sleepy3 = Get-KwEntry $stats3 "Telegram" "sleepy term" $false
    Assert-Eq (Get-KwEffectiveState $sleepy3 $now) "sleep" "revive rolled back"
    $weighty3 = Get-KwEntry $stats3 "Telegram" "weighty term" $false
    Assert-True ([double]$weighty3["weight"] -eq 1.0) "weight restored"
    $rb2 = Rollback-KwTrendBatch $tmp $cfgPath $batchId $now
    Assert-True (-not $rb2.ok) "rollback is idempotent-guarded"
    Assert-Eq $rb2.error "batch_not_applied" "second rollback rejected"
  }

  T "rollback-conflict-after-manual-change" {
    $a = New-SignalIds "new trading term"
    $d = New-SignalIds "weighty term"
    $items = @((New-Suggestion "downweight" "Telegram" "weighty term" $d))
    $inv = New-FakeInvoker (New-JsonSuggestions $items)
    $r = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig) $now -Force -AiInvoker $inv
    $bid = [string]$r.batch.id
    $null = Apply-KwTrendBatch $tmp $cfgPath $bid $now
    $st = Read-KwStats $tmp
    $e = Get-KwEntry $st "Telegram" "weighty term" $false
    $e["weight"] = 0.9
    Save-KwStats $tmp $st | Out-Null
    $rb = Rollback-KwTrendBatch $tmp $cfgPath $bid $now
    Assert-True $rb.ok "rollback ok with conflict"
    Assert-True (@($rb.results | Where-Object { $_.status -eq "conflict" }).Count -ge 1) "conflict reported"
    $st2 = Read-KwStats $tmp
    $e2 = Get-KwEntry $st2 "Telegram" "weighty term" $false
    Assert-Eq $e2["weight"] 0.9 "conflict leaves manual value"
  }

  T "not-due-after-successful-run" {
    $ids = @(New-SignalIds "new trading term")
    $items = @((New-Suggestion "add" "Telegram" "due term" $ids))
    $inv = New-FakeInvoker (New-JsonSuggestions $items)
    $r1 = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig) $now -Force -AiInvoker $inv
    Assert-True $r1.ok "first ok"
    $r2 = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig) $now.AddHours(1) -AiInvoker $inv
    Assert-True $r2.ok "not_due is ok"
    Assert-Eq $r2.status "not_due" "status"
  }

  T "empty-suggestions-status" {
    $inv = New-FakeInvoker '{"suggestions":[]}'
    $r = New-KwTrendSuggestions $tmp $cfgPath (New-TestConfig) $now -Force -AiInvoker $inv -NoWrite
    Assert-True $r.ok "ok"
    Assert-Eq $r.status "no_suggestions" "status"
    Assert-Eq @($r.suggestions).Count 0 "none"
  }

  T "view-does-not-leak-key" {
    $v = Get-KwTrendView $tmp (New-TestConfig) 8 $now
    Assert-True $v.ok "view ok"
    Assert-True ($null -ne $v.ai) "ai info"
    Assert-True (-not ([string]$v | Select-String -Pattern "test-key-not-real" -Quiet)) "key not leaked"
    Assert-True ($v.budget.limit -ge 0) "budget limit"
  }
}
finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
