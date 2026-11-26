# lib/round_report.ps1 — 每轮简短中文报告（计划、各平台新增/已存在/未确认/失败、原因、总结果）
# 纯格式化，无 I/O；供 hub、run_daily 与离线测试共用。 

function New-PlatformResult {
  param(
    [string]$Platform = "",
    [string]$Result = "未运行",
    [int]$Joined = 0,
    [int]$Existing = 0,
    [int]$Local = 0,
    [int]$Unconfirmed = 0,
    [int]$Failed = 0,
    [int]$Skipped = 0,
    [string]$Reason = ""
  )
  return [pscustomobject]@{
    platform = [string]$Platform
    result = [string]$Result
    joined = [int]$Joined
    existing = [int]$Existing
    local = [int]$Local
    unconfirmed = [int]$Unconfirmed
    failed = [int]$Failed
    skipped = [int]$Skipped
    reason = [string]$Reason
  }
}

function Get-PlatformResultField {
  param($Result, [string]$Name, $Default = 0)
  if (-not $Result) { return $Default }
  try {
    $p = $Result.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
  } catch { }
  try {
    if ($Result -is [hashtable] -and $Result.ContainsKey($Name)) { return $Result[$Name] }
  } catch { }
  return $Default
}

function Get-PlatformResultLine {
  param($Result)
  if (-not $Result) { return "" }
  $p = [string](Get-PlatformResultField $Result "platform" "")
  $state = [string](Get-PlatformResultField $Result "result" "未运行")
  $joined = [int](Get-PlatformResultField $Result "joined" 0)
  $existing = [int](Get-PlatformResultField $Result "existing" 0)
  $unconfirmed = [int](Get-PlatformResultField $Result "unconfirmed" 0)
  $failed = [int](Get-PlatformResultField $Result "failed" 0)
  $local = [int](Get-PlatformResultField $Result "local" 0)
  $reason = [string](Get-PlatformResultField $Result "reason" "")
  if ($state -eq "未运行") {
    $line = $p + "：未运行"
  } else {
    $line = $p + "：" + $state + "；新增 " + $joined + "，已存在 " + $existing + "，未确认 " + $unconfirmed + "，失败 " + $failed
    if ($local -gt 0) { $line += "，本地 " + $local }
  }
  if ($reason) { $line += "（" + $reason + "）" }
  return $line
}

function New-RoundReport {
  param(
    [string[]]$Plan = @(),
    [hashtable]$Results = @{},
    [datetime]$StartedAt = (Get-Date),
    [datetime]$EndedAt = (Get-Date),
    [string]$Code = "complete",
    [string]$StopReason = "",
    [int]$LateCount = 0,
    [string]$RunId = ""
  )
  $planList = @($Plan | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
  $lines = New-Object System.Collections.ArrayList
  $startTxt = $StartedAt.ToString("yyyy-MM-dd HH:mm")
  $endTxt = $EndedAt.ToString("HH:mm")
  $mins = [int][Math]::Max(0, [Math]::Round(($EndedAt - $StartedAt).TotalMinutes))
  [void]$lines.Add("本轮 " + $startTxt + " → " + $endTxt + "（" + $mins + " 分钟）")
  [void]$lines.Add("计划：" + ($(if ($planList.Count -gt 0) { $planList -join " → " } else { "无" })))
  $totalJoined = 0; $totalExisting = 0; $totalUnconfirmed = 0; $totalFailed = 0
  foreach ($p in $planList) {
    $r = $null
    try { if ($Results -and $Results.ContainsKey($p)) { $r = $Results[$p] } } catch { }
    if (-not $r) { $r = New-PlatformResult -Platform $p -Result "未运行" }
    if (-not (Get-PlatformResultField $r "platform" "")) {
      $r = New-PlatformResult -Platform $p -Result ([string](Get-PlatformResultField $r "result" "未运行"))
    }
    $totalJoined += [int](Get-PlatformResultField $r "joined" 0)
    $totalExisting += [int](Get-PlatformResultField $r "existing" 0)
    $totalUnconfirmed += [int](Get-PlatformResultField $r "unconfirmed" 0)
    $totalFailed += [int](Get-PlatformResultField $r "failed" 0)
    [void]$lines.Add((Get-PlatformResultLine $r))
  }
  if ($LateCount -gt 0) { [void]$lines.Add("迟到回执：" + $LateCount + " 条已隔离，未计入本轮") }
  $verdict = "完成"
  if ($Code -eq "partial_complete") { $verdict = "部分完成（" + $totalUnconfirmed + " 个未确认）" }
  elseif ($Code -eq "stopped") { $verdict = "人工停止" }
  elseif ($Code -eq "emergency_stopped") { $verdict = "全局急停" }
  elseif ($Code -eq "global_failure") { $verdict = "共享故障停止" }
  elseif ($Code -eq "failed_cap") { $verdict = "连续失败停止" }
  elseif ($Code -eq "platform_failure") { $verdict = "平台失败停止" }
  elseif ($Code -ne "complete") { $verdict = [string]$Code }
  $summary = "总结果：" + $verdict + "；新增 " + $totalJoined + "，已存在 " + $totalExisting + "，未确认 " + $totalUnconfirmed + "，失败 " + $totalFailed
  if ($StopReason) { $summary += "（" + $StopReason + "）" }
  [void]$lines.Add($summary)
  $text = ($lines -join "`n")
  return [pscustomobject]@{
    run_id = [string]$RunId
    plan = @($planList)
    results = $Results
    lines = @($lines)
    text = $text
    summary = $summary
    code = [string]$Code
    ok = ($Code -eq "complete")
    late_count = [int]$LateCount
  }
}

function Get-HubRoundReport {
  param($State, [string]$Code = "complete", [string]$StopReason = "")
  $plan = @()
  try { $plan = @($State.plan) } catch { }
  $stats = $null
  try { $stats = $State.platformStats } catch { }
  $results = @{}
  foreach ($p in $plan) {
    $r = $null
    try { if ($stats -and $stats.ContainsKey($p)) { $r = $stats[$p] } } catch { }
    if (-not $r) { $r = New-PlatformResult -Platform $p -Result "未运行" }
    $results[[string]$p] = $r
  }
  $started = (Get-Date)
  try { if ($State.started) { $started = [datetime]$State.started } } catch { }
  $late = 0
  try { $late = @($State.lateReceipts).Count } catch { }
  return (New-RoundReport -Plan $plan -Results $results -StartedAt $started -EndedAt (Get-Date) -Code $Code -StopReason $StopReason -LateCount $late -RunId ([string]$State.planRunId))
}
