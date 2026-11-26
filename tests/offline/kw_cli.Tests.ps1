# tests/offline/kw_cli.Tests.ps1
# 覆盖 kw_weekly.ps1 真实进程入口：Status / ApplyBatch / RollbackBatch / Weekly(no_key) / DryRun 拒绝。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($got, $want, [string]$msg) { if ([string]$got -ne [string]$want) { throw ("$msg got=$got want=$want") } }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\kw_stats.ps1")
. (Join-Path $root "lib\kw_trend.ps1")

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kw_cli_test_" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $tmp "data") -Force
$cfgPath = Join-Path $tmp "config.json"
$now = [datetime]"2026-11-26T12:00:00"
$scriptPath = Join-Path $root "kw_weekly.ps1"

$cfg = [pscustomobject]@{
  strategy = [pscustomobject]@{ Telegram = [pscustomobject]@{ discovery = [pscustomobject]@{ keywords = @("existing term") } } }
  keywordPool = @()
  ai = [pscustomobject]@{ provider = "deepseek"; base_url = "https://api.deepseek.com"; model = "deepseek-chat"; api_key = "test-key-not-real"; timeout = 30 }
  kw_evolve = [pscustomobject]@{ enabled = $true; ai_enabled = $true; ai_weekly_budget_cny = 10.0 }
}
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($true)))
$ledger = @(
  '{"ts":"2026-11-25T10:00:00","platform":"Telegram","source_id":"src-001","query":"cli new term","raw":5,"eligible":2,"joined":1}'
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $tmp "data\source_ledger.jsonl"), $ledger, (New-Object Text.UTF8Encoding($false)))
$null = Register-KwRoundResult $tmp "Telegram" "tracked term" 2 1 $false "r1" "" $now

function Run-Cli {
  param([string[]]$cliArgs)
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @cliArgs 2>&1
  $script:lastExit = $LASTEXITCODE
  return @($out | ForEach-Object { [string]$_ })
}

try {
  T "status-cli" {
    $out = Run-Cli -cliArgs @("-Status", "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 0 "exit"
    $text = $out -join "`n"
    Assert-True ($text -match "关键词状态") "has status heading"
    Assert-True ($text -match "AI 热点建议") "has ai heading"
  }

  T "weekly-no-key-cli" {
    $c2 = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $c2.ai.api_key = ""
    [IO.File]::WriteAllText($cfgPath, ($c2 | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($true)))
    $out = Run-Cli -cliArgs @("-Weekly", "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 0 "exit"
    Assert-True (($out -join "`n") -match "no_key") "explicit no_key"
    $c2.ai.api_key = "test-key-not-real"
    [IO.File]::WriteAllText($cfgPath, ($c2 | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($true)))
  }

  T "generate-batch-for-apply" {
    $sigs = @(Get-KwLedgerSignals $tmp 14 60 $now)
    $sig = @($sigs | Where-Object { ([string]$_.query) -eq "cli new term" })[0]
    Assert-True ($null -ne $sig -and @($sig.sources).Count -ge 1) "ledger signal exists"
    $items = @([ordered]@{ action = "add"; platform = "Telegram"; keyword = "cli applied term"; reason = "dated source"; confidence = 0.8; source_ids = @([string](@($sig.sources)[0])) })
    $json = ([ordered]@{ suggestions = $items } | ConvertTo-Json -Depth 8)
    $inv = { param($ai, $system, $user) [pscustomobject]@{ ok = $true; text = $json; usage = [pscustomobject]@{ prompt_tokens = 10; completion_tokens = 10 } } }.GetNewClosure()
    $r = New-KwTrendSuggestions -BaseDir $tmp -ConfigPath $cfgPath -Config (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) -Now $now -Force -AiInvoker $inv
    Assert-True $r.ok "generated"
    $script:batchId = [string]$r.batch.id
    Assert-True ($script:batchId -like "kwt-*") "batch id"
  }

  T "apply-cli" {
    $out = Run-Cli -cliArgs @("-ApplyBatch", $script:batchId, "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 0 "exit"
    $text = $out -join "`n"
    Assert-True ($text -match "applied") "output applied"
    $c = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($c.strategy.Telegram.discovery.keywords) -contains "cli applied term") "keyword written"
  }

  T "rollback-cli" {
    $out = Run-Cli -cliArgs @("-RollbackBatch", $script:batchId, "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 0 "exit"
    $text = $out -join "`n"
    Assert-True ($text -match "rolled_back") "output rolled_back"
    $c = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($c.strategy.Telegram.discovery.keywords) -notcontains "cli applied term") "keyword removed"
  }

  T "dry-run-does-not-apply" {
    $out = Run-Cli -cliArgs @("-Weekly", "-DryRun", "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 0 "exit"
    $out2 = Run-Cli -cliArgs @("-ApplyBatch", $script:batchId, "-DryRun", "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 2 "dry-run apply rejected"
    Assert-True (($out2 -join "`n") -match "DryRun") "explains refusal"
  }

  T "status-json" {
    $out = Run-Cli -cliArgs @("-Status", "-Json", "-BaseDir", $tmp)
    Assert-Eq $script:lastExit 0 "exit"
    $o = ($out -join "`n") | ConvertFrom-Json
    Assert-True ([bool]$o.ok) "json ok"
    Assert-True ($null -ne $o.policy) "json policy"
  }
}
finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
