# lib/kw_api.ps1 -- 关键词淘汰与 AI 热点建议 HTTP API
# 由 hub.ps1 在 /api/config 之后挂载：if ($path -like "/api/kw/*") { Invoke-KwApi ...; continue }
# 依赖 lib/kw_stats.ps1、lib/kw_trend.ps1；不返回 API Key。

if (-not (Get-Command Get-KwStatus -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot "kw_stats.ps1")
}
if (-not (Get-Command Get-KwTrendView -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot "kw_trend.ps1")
}

function Get-KwQueryValue([string]$Query, [string]$Name) {
  if (-not $Query) { return "" }
  $q = $Query.Trim()
  if ($q.StartsWith("?")) { $q = $q.Substring(1) }
  foreach ($pair in @($q.Split("&"))) {
    if (-not $pair) { continue }
    $kv = $pair.Split("=", 2)
    $k = $kv[0]
    try { $k = [uri]::UnescapeDataString($k) } catch { }
    if ($k -ne $Name) { continue }
    if ($kv.Count -lt 2) { return "" }
    try { return [uri]::UnescapeDataString($kv[1]) } catch { return $kv[1] }
  }
  return ""
}

function ConvertFrom-KwApiBody([string]$Body) {
  if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
  try { return ($Body | ConvertFrom-Json) } catch { return $null }
}

function Get-KwApiBool($Value) {
  if ($null -eq $Value) { return $false }
  $s = ([string]$Value).Trim().ToLowerInvariant()
  return @("1", "true", "yes", "on") -contains $s
}

function Get-KwApiPolicyView($Config) {
  $p = Get-KwPolicy $Config
  return [pscustomobject]@{
    enabled              = [bool]$p.enabled
    zero_rounds          = [int]$p.zero_rounds
    first_sleep_hours    = [int]$p.first_sleep_hours
    second_sleep_hours   = [int]$p.second_sleep_hours
    ai_enabled           = [bool]$p.ai_enabled
    ai_window_days       = [int]$p.ai_window_days
    ai_max_suggestions   = [int]$p.ai_max_suggestions
    ai_max_tokens        = [int]$p.ai_max_tokens
    ai_weekly_budget_cny = [double]$p.ai_weekly_budget_cny
    ai_price_in_per_m    = [double]$p.ai_price_in_per_m
    ai_price_out_per_m   = [double]$p.ai_price_out_per_m
  }
}

function Set-KwApiPolicy([string]$ConfigPath, $Config, $Body, [string]$BaseDir) {
  if ($null -eq $Body) { return [pscustomobject]@{ ok = $false; error = "bad_body" } }
  if (-not (Test-Path -LiteralPath $ConfigPath)) { return [pscustomobject]@{ ok = $false; error = "config_not_found" } }
  $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  $cfg = $null
  try { $cfg = $text | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; error = "config_invalid" } }
  if ($null -eq $cfg) { return [pscustomobject]@{ ok = $false; error = "config_invalid" } }
  if (-not ($cfg.PSObject.Properties.Name -contains "kw_evolve") -or $null -eq $cfg.kw_evolve) {
    $cfg | Add-Member -NotePropertyName kw_evolve -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $k = $cfg.kw_evolve
  $intFields = @{
    zero_rounds        = @(1, 10)
    first_sleep_hours  = @(1, 8760)
    second_sleep_hours = @(1, 8760)
    ai_window_days     = @(1, 90)
    ai_max_suggestions = @(1, 5)
    ai_max_tokens      = @(128, 4000)
  }
  $floatFields = @{
    ai_weekly_budget_cny = @(0, 100000)
    ai_price_in_per_m    = @(0, 100000)
    ai_price_out_per_m   = @(0, 100000)
  }
  $boolFields = @("enabled", "ai_enabled")
  $changed = $false
  foreach ($name in @($intFields.Keys)) {
    $raw = $Body.$name
    if ($null -eq $raw -or [string]$raw -eq "") { continue }
    $v = 0
    try { $v = [int]$raw } catch { return [pscustomobject]@{ ok = $false; error = ("bad_" + $name) } }
    $rng = $intFields[$name]
    if ($v -lt [int]$rng[0] -or $v -gt [int]$rng[1]) { return [pscustomobject]@{ ok = $false; error = ("bad_" + $name) } }
    $k | Add-Member -NotePropertyName $name -NotePropertyValue $v -Force
    $changed = $true
  }
  foreach ($name in @($floatFields.Keys)) {
    $raw = $Body.$name
    if ($null -eq $raw -or [string]$raw -eq "") { continue }
    $v = 0.0
    try { $v = [double]$raw } catch { return [pscustomobject]@{ ok = $false; error = ("bad_" + $name) } }
    $rng = $floatFields[$name]
    if ($v -lt [double]$rng[0] -or $v -gt [double]$rng[1]) { return [pscustomobject]@{ ok = $false; error = ("bad_" + $name) } }
    $k | Add-Member -NotePropertyName $name -NotePropertyValue $v -Force
    $changed = $true
  }
  foreach ($name in $boolFields) {
    $raw = $Body.$name
    if ($null -eq $raw) { continue }
    $k | Add-Member -NotePropertyName $name -NotePropertyValue (Get-KwApiBool $raw) -Force
    $changed = $true
  }
  if (-not $changed) { return [pscustomobject]@{ ok = $false; error = "no_fields" } }
  try {
    $json = $cfg | ConvertTo-Json -Depth 16
    Write-KwTextFilePreserveBom $ConfigPath $json
  } catch {
    return [pscustomobject]@{ ok = $false; error = "save_failed"; detail = (ConvertTo-KwText $_.Exception.Message 200) }
  }
  if ($null -ne $Config) {
    try { $Config | Add-Member -NotePropertyName kw_evolve -NotePropertyValue $k -Force } catch { }
  }
  return [pscustomobject]@{ ok = $true; policy = (Get-KwApiPolicyView $Config) }
}

function Invoke-KwApi {
  param(
    $Context,
    [string]$Path,
    [string]$Method,
    [string]$Query,
    [string]$Body,
    [string]$BaseDir,
    $Config,
    [scriptblock]$Responder = $null,
    [scriptblock]$BackgroundLauncher = $null
  )
  $send = {
    param($ctx, $code, $obj)
    if ($null -ne $Responder) { & $Responder $ctx $code $obj } else { Send-Json $ctx $code $obj }
  }
  $methodName = ([string]$Method).Trim().ToUpperInvariant()
  $data = ConvertFrom-KwApiBody $Body
  try {
    if ($Path -eq "/api/kw/status") {
      if ($methodName -ne "GET") { & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" }); return $true }
      $platform = Get-KwQueryValue $Query "platform"
      $status = Get-KwStatus -BaseDir $BaseDir -Platform $platform
      $trend = Get-KwTrendView -BaseDir $BaseDir -Config $Config -BatchLimit 6
      $res = [pscustomobject]@{
        ok      = $true
        status  = $status
        policy  = (Get-KwApiPolicyView $Config)
        trend   = $trend
      }
      & $send $Context 200 $res
      return $true
    }
    if ($Path -eq "/api/kw/action") {
      if ($methodName -ne "POST") { & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" }); return $true }
      if ($null -eq $data) { & $send $Context 400 ([pscustomobject]@{ ok = $false; error = "bad_body" }); return $true }
      $res = Set-KwKeywordState -BaseDir $BaseDir -Platform ([string]$data.platform) -Keyword ([string]$data.keyword) -Action ([string]$data.action) -Hours ([int]$data.hours) -Note ([string]$data.note)
      & $send $Context 200 $res
      return $true
    }
    if ($Path -eq "/api/kw/trend") {
      if ($methodName -ne "GET") { & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" }); return $true }
      $batchId = Get-KwQueryValue $Query "batch"
      if ($batchId) {
        & $send $Context 200 (Get-KwTrendBatchView -BaseDir $BaseDir -BatchId $batchId)
      } else {
        & $send $Context 200 (Get-KwTrendView -BaseDir $BaseDir -Config $Config -BatchLimit 10)
      }
      return $true
    }
    if ($Path -eq "/api/kw/trend/generate") {
      if ($methodName -ne "POST") { & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" }); return $true }
      $force = $false
      if ($null -ne $data) { $force = Get-KwApiBool $data.force }
      $policy = Get-KwPolicy $Config
      if (-not $policy.enabled) { & $send $Context 200 ([pscustomobject]@{ ok = $false; status = "disabled"; message = "关键词演化已关闭" }); return $true }
      if (-not $policy.ai_enabled) { & $send $Context 200 ([pscustomobject]@{ ok = $false; status = "ai_disabled"; message = "AI 已关闭" }); return $true }
      $ai = Get-KwAiSettings $Config
      if (-not $ai.has_key) { & $send $Context 200 ([pscustomobject]@{ ok = $false; status = "no_key"; message = "未配置 AI API Key"; masked = $ai.masked }); return $true }
      if (-not $force -and -not (Test-KwTrendDue $BaseDir $null)) { & $send $Context 200 ([pscustomobject]@{ ok = $false; status = "not_due"; message = "本周已运行过，可 force 重跑" }); return $true }
      $budget = Get-KwTrendBudget $BaseDir $policy $null
      if ($budget.blocked) { & $send $Context 200 ([pscustomobject]@{ ok = $false; status = "budget_exceeded"; message = "本周 AI 预算不足"; budget = $budget }); return $true }
      $ledgerSignals = @(Get-KwLedgerSignals $BaseDir $policy.ai_window_days 60 $null)
      $hotSettings = Get-KwHotSettings $Config
      $hotPossible = ([bool]$hotSettings.enabled -and (Test-KwCs2Context $Config))
      if ($ledgerSignals.Count -eq 0 -and -not $hotPossible) {
        & $send $Context 200 ([pscustomobject]@{ ok = $false; status = "no_signals"; message = "近期没有可用信号，热点源也未启用" })
        return $true
      }
      $lockPath = Get-KwTrendLockPath $BaseDir
      if (Test-Path -LiteralPath $lockPath) {
        $age = 999999
        try { $age = ((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalSeconds } catch { }
        if ($age -lt 600) { & $send $Context 202 ([pscustomobject]@{ ok = $true; status = "running"; message = "已有生成任务在运行"; poll = "/api/kw/trend" }); return $true }
      }
      $configPath = Join-Path $BaseDir "config.json"
      $logDir = Join-Path $BaseDir "logs"
      if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
      $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
      $outLog = Join-Path $logDir ("kw_evolve_manual-" + $stamp + ".out.log")
      $errLog = Join-Path $logDir ("kw_evolve_manual-" + $stamp + ".err.log")
      $procId = 0
      try {
        if ($null -ne $BackgroundLauncher) {
          $launched = & $BackgroundLauncher $BaseDir $configPath $outLog $errLog
          if ($null -ne $launched) { try { $procId = [int]$launched.Id } catch { $procId = [int]$launched } }
        } else {
          $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $BaseDir "kw_weekly.ps1"), "-Weekly", "-Force", "-BaseDir", $BaseDir, "-ConfigPath", $configPath)
          $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
          $procId = [int]$proc.Id
        }
      } catch {
        & $send $Context 500 ([pscustomobject]@{ ok = $false; status = "spawn_failed"; message = ("后台任务启动失败：" + $_.Exception.Message); retryable = $true })
        return $true
      }
      & $send $Context 202 ([pscustomobject]@{ ok = $true; status = "queued"; message = "已提交后台生成，稍后刷新"; poll = "/api/kw/trend"; pid = $procId })
      return $true
    }
    if ($Path -eq "/api/kw/trend/apply") {
      if ($methodName -ne "POST") { & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" }); return $true }
      if ($null -eq $data -or -not $data.batch_id) { & $send $Context 400 ([pscustomobject]@{ ok = $false; error = "batch_id_required" }); return $true }
      $res = Apply-KwTrendBatch -BaseDir $BaseDir -ConfigPath (Join-Path $BaseDir "config.json") -BatchId ([string]$data.batch_id)
      & $send $Context 200 $res
      return $true
    }
    if ($Path -eq "/api/kw/trend/rollback") {
      if ($methodName -ne "POST") { & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" }); return $true }
      if ($null -eq $data -or -not $data.batch_id) { & $send $Context 400 ([pscustomobject]@{ ok = $false; error = "batch_id_required" }); return $true }
      $res = Rollback-KwTrendBatch -BaseDir $BaseDir -ConfigPath (Join-Path $BaseDir "config.json") -BatchId ([string]$data.batch_id)
      & $send $Context 200 $res
      return $true
    }
    if ($Path -eq "/api/kw/policy") {
      if ($methodName -eq "GET") {
        & $send $Context 200 ([pscustomobject]@{ ok = $true; policy = (Get-KwApiPolicyView $Config) })
        return $true
      }
      if ($methodName -eq "POST") {
        $res = Set-KwApiPolicy -ConfigPath (Join-Path $BaseDir "config.json") -Config $Config -Body $data -BaseDir $BaseDir
        & $send $Context 200 $res
        return $true
      }
      & $send $Context 405 ([pscustomobject]@{ ok = $false; error = "method_not_allowed" })
      return $true
    }
    & $send $Context 404 ([pscustomobject]@{ ok = $false; error = "not_found" })
    return $true
  } catch {
    try { & $send $Context 500 ([pscustomobject]@{ ok = $false; error = "kw_api_error"; detail = (ConvertTo-KwText $_.Exception.Message 300) }) } catch { }
    return $true
  }
}
