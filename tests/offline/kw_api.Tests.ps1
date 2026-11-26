# tests/offline/kw_api.Tests.ps1
# 覆盖：HTTP API 路由、策略写入并回写内存 config、无 key 状态、无 key 泄漏。
$ErrorActionPreference = "Stop"
$fail = 0; $pass = 0
function T([string]$name, [scriptblock]$body) {
  try { & $body; $script:pass++; "PASS  $name" }
  catch { $script:fail++; "FAIL  $name :: $($_.Exception.Message)" }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($got, $want, [string]$msg) { if ([string]$got -ne [string]$want) { throw ("$msg got=$got want=$want") } }
function Assert-NoKey($obj) { $json = ($obj | ConvertTo-Json -Depth 12 -Compress); if ($json -match "test-key-not-real") { throw "api key leaked" } }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "lib\kw_stats.ps1")
. (Join-Path $root "lib\kw_trend.ps1")
. (Join-Path $root "lib\kw_api.ps1")

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kw_api_test_" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path (Join-Path $tmp "data") -Force
$cfgPath = Join-Path $tmp "config.json"
$cfg = [pscustomobject]@{
  strategy = [pscustomobject]@{ Telegram = [pscustomobject]@{ discovery = [pscustomobject]@{ keywords = @("existing term") } } }
  keywordPool = @()
  ai = [pscustomobject]@{ provider = "deepseek"; base_url = "https://api.deepseek.com"; model = "deepseek-chat"; api_key = "test-key-not-real"; timeout = 30 }
  kw_evolve = [pscustomobject]@{ enabled = $true; ai_enabled = $true; ai_max_suggestions = 5 }
}
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($true)))
$script:lastCode = 0; $script:lastObj = $null
$responder = { param($ctx, $code, $obj) $script:lastCode = [int]$code; $script:lastObj = $obj }
function CallApi([string]$path, [string]$method, [string]$query = "", [string]$body = "") {
  $script:lastCode = 0; $script:lastObj = $null
  $null = Invoke-KwApi -Context $null -Path $path -Method $method -Query $query -Body $body -BaseDir $tmp -Config $cfg -Responder $responder
}

try {
  T "status-route" {
    CallApi "/api/kw/status" "GET"
    Assert-Eq $script:lastCode 200 "code"
    Assert-True ([bool]$script:lastObj.ok) "ok"
    Assert-True ($null -ne $script:lastObj.policy) "policy"
    Assert-Eq $script:lastObj.policy.ai_max_suggestions 5 "max suggestions"
    Assert-NoKey $script:lastObj
  }

  T "action-protect" {
    CallApi "/api/kw/action" "POST" "" '{"platform":"Telegram","keyword":"protected api term","action":"protect"}'
    Assert-Eq $script:lastCode 200 "code"
    Assert-True ([bool]$script:lastObj.ok) "ok"
    $e = Get-KwEntry (Read-KwStats $tmp) "Telegram" "protected api term" $false
    Assert-True ([bool]$e["protected"]) "protected persisted"
  }

  T "policy-post-mutates-config-and-file" {
    CallApi "/api/kw/policy" "POST" "" '{"ai_max_suggestions":4,"first_sleep_hours":2,"ai_weekly_budget_cny":3.5}'
    Assert-Eq $script:lastCode 200 "code"
    Assert-True ([bool]$script:lastObj.ok) "ok"
    Assert-Eq $cfg.kw_evolve.ai_max_suggestions 4 "in-memory config mutated"
    $saved = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Eq $saved.kw_evolve.ai_max_suggestions 4 "file max"
    Assert-Eq $saved.kw_evolve.first_sleep_hours 2 "file first"
    Assert-True ([double]$saved.kw_evolve.ai_weekly_budget_cny -eq 3.5) "file budget"
  }

  T "policy-rejects-nine" {
    CallApi "/api/kw/policy" "POST" "" '{"ai_max_suggestions":9}'
    Assert-Eq $script:lastCode 200 "code"
    Assert-True (-not [bool]$script:lastObj.ok) "not ok"
    Assert-Eq $script:lastObj.error "bad_ai_max_suggestions" "error"
  }

  T "generate-no-key-is-explicit" {
    $cfg.ai.api_key = ""
    CallApi "/api/kw/trend/generate" "POST" "" '{"force":true}'
    Assert-Eq $script:lastCode 200 "code"
    Assert-True (-not [bool]$script:lastObj.ok) "not ok"
    Assert-Eq $script:lastObj.status "no_key" "status"
    Assert-NoKey $script:lastObj
    $cfg.ai.api_key = "test-key-not-real"
  }

  T "apply-missing-batch" {
    CallApi "/api/kw/trend/apply" "POST" "" '{"batch_id":"kwt-missing"}'
    Assert-Eq $script:lastCode 200 "code"
    Assert-True (-not [bool]$script:lastObj.ok) "not ok"
    Assert-Eq $script:lastObj.error "batch_not_found" "error"
  }

  T "bad-body-and-unknown-route" {
    CallApi "/api/kw/action" "POST" "" "{not json"
    Assert-Eq $script:lastCode 400 "bad body code"
    CallApi "/api/kw/nope" "GET"
    Assert-Eq $script:lastCode 404 "unknown code"
  }

  T "trend-view-route" {
    CallApi "/api/kw/trend" "GET"
    Assert-Eq $script:lastCode 200 "code"
    Assert-True ([bool]$script:lastObj.ok) "ok"
    Assert-True ($null -ne $script:lastObj.budget) "budget"
  }
}
finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

"RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
