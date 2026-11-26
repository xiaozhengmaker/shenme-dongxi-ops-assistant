# kw_weekly.ps1 -- 平台关键词淘汰与 AI 热点建议命令行
# 默认基于本脚本所在目录，不写死生产路径；只读写该目录下 data/ 与 config.json。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File kw_weekly.ps1 -Status
#   powershell -NoProfile -ExecutionPolicy Bypass -File kw_weekly.ps1 -Weekly
#   powershell -NoProfile -ExecutionPolicy Bypass -File kw_weekly.ps1 -Force -Json
#   powershell -NoProfile -ExecutionPolicy Bypass -File kw_weekly.ps1 -ApplyBatch kwt-...
#   powershell -NoProfile -ExecutionPolicy Bypass -File kw_weekly.ps1 -RollbackBatch kwt-...
[CmdletBinding()]
param(
  [switch]$Weekly,
  [switch]$Force,
  [switch]$Status,
  [string]$ApplyBatch = "",
  [string]$RollbackBatch = "",
  [switch]$Json,
  [string]$BaseDir = "",
  [string]$ConfigPath = "",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
if (-not $BaseDir) { $BaseDir = $scriptRoot }
$BaseDir = [IO.Path]::GetFullPath($BaseDir)
if (-not $ConfigPath) { $ConfigPath = Join-Path $BaseDir "config.json" }

# 代码始终从脚本所在目录的 lib 加载；-BaseDir 只决定数据/config 的读写目录，
# 因此可以用独立临时数据目录做行为测试而不碰真实 data/。
$lib = Join-Path $scriptRoot "lib"
. (Join-Path $lib "kw_stats.ps1")
. (Join-Path $lib "kw_trend.ps1")

$actions = 0
if ($Weekly) { $actions++ }
if ($Status) { $actions++ }
if ($ApplyBatch) { $actions++ }
if ($RollbackBatch) { $actions++ }
if ($actions -ne 1) {
  Write-Output "用法: kw_weekly.ps1 -Weekly|-Status|-ApplyBatch <id>|-RollbackBatch <id> [-Force] [-Json] [-DryRun] [-BaseDir <dir>] [-ConfigPath <file>]"
  exit 2
}
if ($DryRun -and ($ApplyBatch -or $RollbackBatch)) {
  Write-Output "DryRun 只用于 -Weekly；应用/回滚必须显式执行。"
  exit 2
}

$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
  try { $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $config = $null }
}

function Write-KwCliResult($Result, [string]$Title) {
  if ($Json) {
    $Result | ConvertTo-Json -Depth 16
    return
  }
  Write-Output ("[" + $Title + "]")
  $status = ""
  try { $status = [string]$Result.status } catch { }
  if ($status) { Write-Output ("状态: " + $status) }
  if ($Result.PSObject.Properties.Name -contains "message" -and $Result.message) {
    Write-Output ("说明: " + [string]$Result.message)
  }
  if ($Result.PSObject.Properties.Name -contains "signals_count") {
    Write-Output ("信号数: " + [int]$Result.signals_count)
  }
  if ($Result.PSObject.Properties.Name -contains "budget" -and $null -ne $Result.budget) {
    $b = $Result.budget
    Write-Output ("本周预算: 已用 " + [math]::Round([double]$b.spent, 4) + " / " + [math]::Round([double]$b.limit, 4) + " CNY，剩余 " + [math]::Round([double]$b.remaining, 4))
  }
  if ($Result.PSObject.Properties.Name -contains "rejected" -and @($Result.rejected).Count -gt 0) {
    Write-Output ("被拒建议: " + @($Result.rejected).Count)
  }
  if ($Result.PSObject.Properties.Name -contains "batch" -and $null -ne $Result.batch) {
    Write-Output ("批次: " + [string]$Result.batch.id + " (" + [string]$Result.batch.status + ")")
  }
  if ($Result.PSObject.Properties.Name -contains "suggestions") {
    $i = 0
    foreach ($s in @($Result.suggestions)) {
      $i++
      $src = ""
      try { $src = (@($s.sources) | ForEach-Object { [string]$_.source_id }) -join ", " } catch { }
      Write-Output ("  " + $i + ". [" + [string]$s.action + "] " + [string]$s.platform + " / " + [string]$s.keyword + " | 来源: " + $src)
      if ($s.reason) { Write-Output ("     理由: " + [string]$s.reason) }
    }
  }
}

try {
  if ($Status) {
    $st = Get-KwStatus -BaseDir $BaseDir
    $tv = Get-KwTrendView -BaseDir $BaseDir -Config $config -BatchLimit 6
    $pol = Get-KwPolicy $config
    $errCount = 0
    try { $errCount = [int](@($st.keywords | Where-Object { [int]$_.errors -gt 0 }).Count) } catch { }
    $out = [pscustomobject]@{ ok = $true; status = $st; policy = $pol; trend = $tv }
    if ($Json) {
      $out | ConvertTo-Json -Depth 16
    } else {
      $s = $st.summary
      Write-Output "[关键词状态]"
      Write-Output ("平台: " + $(if ($st.platform) { $st.platform } else { "全部" }))
      Write-Output ("关键词: " + [int]$s.total + "，活跃 " + [int]$s.active + "，休眠 " + [int]$s.sleep + "，保护 " + [int]$s.protected + "，手工淘汰 " + [int]$s.manual + "，有过错误 " + $errCount)
      Write-Output ("策略: 连续零 " + [int]$pol.zero_rounds + " 轮 → " + [int]$pol.first_sleep_hours + "h；再 " + [int]$pol.zero_rounds + " 轮 → " + [int]$pol.second_sleep_hours + "h；AI 最多 " + [int]$pol.ai_max_suggestions + " 条")
      Write-Output ""
      Write-Output "[AI 热点建议]"
      if ($tv.ai.configured) { Write-Output ("凭据: 已配置 (" + [string]$tv.ai.masked + ")") } else { Write-Output "凭据: 未配置 API Key（不会调用 AI）" }
      Write-Output ("本周是否到期: " + $(if ($tv.due) { "是" } else { "否" }))
      Write-Output ("上次状态: " + $(if ($tv.last_status) { [string]$tv.last_status } else { "从未运行" }))
      if ($tv.last_error) { Write-Output ("上次错误: " + [string]$tv.last_error) }
      if ($tv.budget) { Write-Output ("本周预算: 已用 " + [math]::Round([double]$tv.budget.spent, 4) + " / " + [math]::Round([double]$tv.budget.limit, 4) + " CNY") }
      if ($tv.last_batch) { Write-Output ("最近批次: " + [string]$tv.last_batch.id + " (" + [string]$tv.last_batch.status + ")") }
      Write-Output ("批次总数: " + @($tv.batches).Count)
    }
    exit 0
  }

  if ($Weekly) {
    $res = New-KwTrendSuggestions -BaseDir $BaseDir -ConfigPath $ConfigPath -Config $config -Force:$Force -NoWrite:$DryRun
    Write-KwCliResult $res "AI 每周建议"
    exit 0
  }

  if ($ApplyBatch) {
    $res = Apply-KwTrendBatch -BaseDir $BaseDir -ConfigPath $ConfigPath -BatchId $ApplyBatch
    Write-KwCliResult $res "应用建议批次"
    exit 0
  }

  if ($RollbackBatch) {
    $res = Rollback-KwTrendBatch -BaseDir $BaseDir -ConfigPath $ConfigPath -BatchId $RollbackBatch
    Write-KwCliResult $res "回滚建议批次"
    exit 0
  }
} catch {
  if ($Json) {
    [pscustomobject]@{ ok = $false; status = "cli_error"; message = (ConvertTo-KwText $_.Exception.Message 500) } | ConvertTo-Json -Depth 8
  } else {
    Write-Output ("执行失败: " + $_.Exception.Message)
  }
  exit 1
}
