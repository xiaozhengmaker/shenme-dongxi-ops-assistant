# tests/offline/kw_hot.Tests.ps1
# 受控热点源、原子锁、completion token 上限、API 异步生成与旧行为兼容。
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
. (Join-Path $root "lib\kw_api.ps1")

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kw_hot_test_" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $tmp "data") -Force
$now = [datetime]"2026-11-26T12:00:00"

function New-Cfg([string]$business = "", [string]$key = "test-key-not-real", [double]$budget = 10.0) {
  $hs = [pscustomobject]@{
    enabled = $true
    max_items = 5
    steam_enabled = $true
    entries = @(
      [pscustomobject]@{ title = "IEM Beijing 2026 schedule"; url = "https://example.com/iem"; date = "2026-11-20"; platform = "Telegram" }
      [pscustomobject]@{ title = "user@example.com private post"; url = "https://example.com/bad"; date = "2026-11-20"; platform = "Telegram" }
      [pscustomobject]@{ title = "bad date entry"; url = "https://example.com/bad2"; date = "not-a-date"; platform = "Telegram" }
    )
  }
  return [pscustomobject]@{
    business = $business
    strategy = [pscustomobject]@{ Telegram = [pscustomobject]@{ discovery = [pscustomobject]@{ keywords = @("existing term") } } }
    keywordPool = @()
    ai = [pscustomobject]@{ provider = "deepseek"; base_url = "https://api.deepseek.com"; model = "deepseek-chat"; api_key = $key; timeout = 30 }
    kw_evolve = [pscustomobject]@{ enabled = $true; ai_enabled = $true; zero_rounds = 3; first_sleep_hours = 24; second_sleep_hours = 168; ai_window_days = 14; ai_max_suggestions = 5; ai_max_tokens = 640; ai_weekly_budget_cny = $budget; hot_sources = $hs }
  }
}
function Add-Ledger {
  $line = (@{ ts = "2026-11-25T10:00:00"; platform = "Telegram"; source_id = "src-hot-1"; query = "ledger term"; raw = 5; eligible = 3; joined = 1 } | ConvertTo-Json -Compress)
  [IO.File]::WriteAllLines((Join-Path $tmp "data\source_ledger.jsonl"), @($line), (New-Object Text.UTF8Encoding($false)))
}
function New-Fetcher([scriptblock]$body) { return $body }

try {
  T "hot-not-cs2-does-not-call-network" {
    $cfg = New-Cfg ""
    $called = 0
    $f = { param($u, $s) $script:called++; throw "must not fetch" }
    $r = Get-KwHotSignals $tmp $cfg (Get-KwPolicy $cfg) $f $now
    Assert-Eq $r.status "not_cs2" "status"
    Assert-Eq @($r.signals).Count 0 "no signals"
    Assert-Eq $called 0 "fetcher must not be called"
  }

  T "hot-cs2-official-and-entry-signals-are-traceable" {
    $cfg = New-Cfg "CS2 skin trading"
    $stamp = ([DateTimeOffset]$now).ToUnixTimeSeconds()
    $f = { param($u, $s) [pscustomobject]@{ appnews = [pscustomobject]@{ newsitems = @(
      [pscustomobject]@{ title = "Counter-Strike 2 Update"; url = "https://store.steampowered.com/news/app/730/view/999"; date = $stamp; gid = "999"; feedlabel = "CS2" }
    ) } } }
    $r = Get-KwHotSignals $tmp $cfg (Get-KwPolicy $cfg) $f $now
    Assert-True ($r.status -eq "ok" -or $r.status -eq "partial") ("status=" + $r.status)
    $sigs = @($r.signals)
    Assert-True ($sigs.Count -ge 2) ("signals=" + $sigs.Count)
    $entry = @($sigs | Where-Object { $_.source_kind -eq "entry" })
    Assert-Eq $entry.Count 1 "personal/invalid entries filtered"
    Assert-Contains ([string]$entry[0].url) "example.com/iem" "entry url"
    $steam = @($sigs | Where-Object { $_.source_kind -eq "steam" })
    Assert-Eq $steam.Count 1 "steam signal"
    Assert-Contains ([string]$steam[0].url) "store.steampowered.com" "steam url"
    $meta = $steam[0].source_meta[$steam[0].sources[0]]
    Assert-Contains ([string]$meta.url) "steampowered.com" "source meta url"
  }

  T "hot-steam-failure-degrades-without-inventing" {
    $cfg = New-Cfg "Counter-Strike 2"
    $f = { param($u, $s) throw "network down" }
    $r = Get-KwHotSignals $tmp $cfg (Get-KwPolicy $cfg) $f $now
    Assert-Eq $r.steam_status "failed" "steam status"
    Assert-True ($r.status -eq "partial" -or $r.status -eq "unavailable") ("status=" + $r.status)
    Assert-True (@($r.warnings).Count -gt 0) "warning"
    $sigs = @($r.signals)
    Assert-True ($sigs.Count -ge 1) "entry still available"
    Assert-True (@($sigs | Where-Object { $_.source_kind -eq "steam" }).Count -eq 0) "no fake steam signal"
  }

  T "prompt-includes-hot-title-url-not-personal-data" {
    $cfg = New-Cfg "CS2"
    $stamp = ([DateTimeOffset]$now).ToUnixTimeSeconds()
    $f = { param($u, $s) [pscustomobject]@{ appnews = [pscustomobject]@{ newsitems = @(
      [pscustomobject]@{ title = "CS2 Major schedule"; url = "https://store.steampowered.com/news/app/730/view/1000"; date = $stamp; gid = "1000"; feedlabel = "CS2" }
    ) } } }
    $r = Get-KwHotSignals $tmp $cfg (Get-KwPolicy $cfg) $f $now
    $p = Get-KwTrendPrompt @($r.signals) @() (Get-KwPolicy $cfg)
    Assert-Contains $p.user "CS2 Major schedule" "hot title"
    Assert-Contains $p.user "store.steampowered.com" "hot url"
    Assert-True (-not ($p.user -match "user@example\.com")) "no personal data"
  }

  T "hot-source-key-is-accepted-in-suggestions" {
    $cfg = New-Cfg "CS2"
    $stamp = ([DateTimeOffset]$now).ToUnixTimeSeconds()
    $f = { param($u, $s) [pscustomobject]@{ appnews = [pscustomobject]@{ newsitems = @(
      [pscustomobject]@{ title = "CS2 Major schedule"; url = "https://store.steampowered.com/news/app/730/view/1001"; date = $stamp; gid = "1001"; feedlabel = "CS2" }
    ) } } }
    $r = Get-KwHotSignals $tmp $cfg (Get-KwPolicy $cfg) $f $now
    $sig = @($r.signals)[0]
    $json = (@{ suggestions = @(@{ action = "add"; platform = "Telegram"; keyword = "cs2 major schedule"; reason = "official update"; source_ids = @($sig.sources[0]); confidence = 0.7 }) } | ConvertTo-Json -Depth 8)
    $parsed = ConvertFrom-KwAiSuggestions $json @($sig) @() $cfg (Get-KwPolicy $cfg) $tmp
    Assert-True $parsed.ok "parsed"
    Assert-Eq @($parsed.suggestions).Count 1 "one suggestion"
    Assert-Contains ([string]$parsed.suggestions[0].sources[0].url) "steampowered.com" "batch source url"
  }

  T "lock-is-atomic-and-stale-is-recoverable" {
    $l1 = Enter-KwTrendLock $tmp $now 600
    Assert-True $l1.ok "first lock"
    $l2 = Enter-KwTrendLock $tmp $now 600
    Assert-True (-not $l2.ok) "second lock busy"
    Assert-Eq $l2.status "busy" "busy status"
    Exit-KwTrendLock $l1
    $l3 = Enter-KwTrendLock $tmp $now 600
    Assert-True $l3.ok "lock after release"
    Exit-KwTrendLock $l3
    $p = Get-KwTrendLockPath $tmp
    [IO.File]::WriteAllText($p, "old")
    [IO.File]::SetLastWriteTime($p, (Get-Date).AddMinutes(-20))
    $l4 = Enter-KwTrendLock $tmp $now 600
    Assert-True $l4.ok "stale lock recovered"
    Exit-KwTrendLock $l4
  }

  T "actual-ai-path-passes-explicit-max-tokens" {
    $cfg = New-Cfg "CS2"
    $cfg.kw_evolve.hot_sources.enabled = $false
    Add-Ledger
    $script:capturedMax = 0
    function global:Invoke-AiChat($aiCfg, $system, $user, [switch]$JsonMode, [int]$MaxTokens = 0) {
      $script:capturedMax = $MaxTokens
      return [pscustomobject]@{ ok = $true; text = '{"suggestions":[]}'; usage = [pscustomobject]@{ prompt_tokens = 10; completion_tokens = 5 } }
    }
    try {
      $r = New-KwTrendSuggestions $tmp (Join-Path $tmp "config.json") $cfg $now -Force
      Assert-Eq $r.status "no_suggestions" "status"
      Assert-Eq $script:capturedMax 640 "max_tokens"
    } finally {
      Remove-Item Function:\Invoke-AiChat -Force -ErrorAction SilentlyContinue
    }
  }

  T "api-generate-queues-without-blocking-and-reuses-lock" {
    $cfg = New-Cfg "CS2" "test-key-not-real"
    Add-Ledger
    $script:apiCode = 0; $script:apiObj = $null; $script:launched = $false
    $resp = { param($ctx, $code, $obj) $script:apiCode = $code; $script:apiObj = $obj }
    $launcher = { param($bd, $cp, $out, $err) $script:launched = $true; return [pscustomobject]@{ Id = 4242 } }
    $ok = Invoke-KwApi -Context $null -Path "/api/kw/trend/generate" -Method "POST" -Query "" -Body '{"force":true}' -BaseDir $tmp -Config $cfg -Responder $resp -BackgroundLauncher $launcher
    Assert-True $ok "handled"
    Assert-Eq $script:apiCode 202 "queued 202"
    Assert-Eq $script:apiObj.status "queued" "queued status"
    Assert-Eq $script:apiObj.pid 4242 "pid"
    Assert-True $script:launched "launcher called"
    $p = Get-KwTrendLockPath $tmp
    [IO.File]::WriteAllText($p, "running")
    $script:apiCode = 0; $script:launched = $false
    $ok = Invoke-KwApi -Context $null -Path "/api/kw/trend/generate" -Method "POST" -Query "" -Body '{"force":true}' -BaseDir $tmp -Config $cfg -Responder $resp -BackgroundLauncher $launcher
    Assert-True $ok "handled running"
    Assert-Eq $script:apiCode 202 "running 202"
    Assert-Eq $script:apiObj.status "running" "running status"
    Assert-True (-not $script:launched) "launcher not called while running"
    Remove-Item -LiteralPath $p -Force
  }

  T "api-generate-keeps-no-key-and-no-signals-explicit" {
    $cfg = New-Cfg "" ""
    $script:apiCode = 0; $script:apiObj = $null
    $resp = { param($ctx, $code, $obj) $script:apiCode = $code; $script:apiObj = $obj }
    $null = Invoke-KwApi -Context $null -Path "/api/kw/trend/generate" -Method "POST" -Query "" -Body '{"force":true}' -BaseDir $tmp -Config $cfg -Responder $resp
    Assert-Eq $script:apiCode 200 "no key 200"
    Assert-Eq $script:apiObj.status "no_key" "no key status"
    $cfg2 = New-Cfg "" "test-key-not-real"
    $empty = Join-Path ([IO.Path]::GetTempPath()) ("kw_hot_empty_" + [guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Path (Join-Path $empty "data") -Force
    $null = Invoke-KwApi -Context $null -Path "/api/kw/trend/generate" -Method "POST" -Query "" -Body '{"force":true}' -BaseDir $empty -Config $cfg2 -Responder $resp
    Assert-Eq $script:apiCode 200 "no signals 200"
    Assert-Eq $script:apiObj.status "no_signals" "no signals status"
    Remove-Item -LiteralPath $empty -Recurse -Force
  }
} finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch { }
}
"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
exit 0
