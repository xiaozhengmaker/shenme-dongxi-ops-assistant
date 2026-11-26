# run_all.ps1 -- 一键全流程：拓群(多平台) -> 成员采样 -> 人数回填 -> Steam 抽样导入 -> 可选日报
# 由看板「开始运行」触发（hub /control {"action":"pipeline"}），也可手动跑。
param(
  [string[]]$Platforms = @("Telegram","Facebook"),
  [switch]$SkipMembers,
  [switch]$SkipSteam,
  [switch]$SkipLeads,
  [switch]$Report,
  [switch]$NoReport,
  [switch]$Fast,
  [int]$WaitTimeoutMin = 90,
  [string]$HubUrl = "http://127.0.0.1:8787",
  [switch]$SkipSelfCheck
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "lib\stop.ps1")
. (Join-Path $PSScriptRoot "lib\platform_run.ps1")
. (Join-Path $PSScriptRoot "lib\pipeline_status.ps1")
. (Join-Path $PSScriptRoot "lib\run_control.ps1")
$baseDir = Split-Path -Parent $PSCommandPath
$hubUrl = $HubUrl
$logDir = Join-Path $baseDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$script:LogFile = Join-Path $logDir "run_all.log"
function Say([string]$msg) {
  $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] " + $msg
  Write-Host $line
  try { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  try {
    $body = @{ msg = $msg } | ConvertTo-Json -Compress
    Invoke-RestMethod "$hubUrl/api/event" -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
  } catch { }
}

function Hub([string]$method, [string]$path, $body) {
  if ($method -eq "GET") { return Invoke-RestMethod ($hubUrl + $path) -TimeoutSec 15 }
  $json = $body | ConvertTo-Json -Compress
  return Invoke-RestMethod ($hubUrl + $path) -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20
}

Say "=== run_all 开始 ==="
$fail = @()
$script:pipePath = Get-PipelineStatusPath -BaseDir $baseDir
$script:pipe = New-PipelineStatus -RunId ("run_all-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + "-" + $PID) -Platforms $Platforms
$runId = [string]$script:pipe.run_id
$global:GOPS_SUMMARY = @{ Done = $false; BaseDir = $baseDir; RunId = $runId; StartedAt = $script:pipe.started_at }
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
  try {
    $g = $global:GOPS_SUMMARY
    if ($g) {
      . (Join-Path $g.BaseDir "lib\run_summary.ps1")
      . (Join-Path $g.BaseDir "lib\run_control.ps1")
      . (Join-Path $g.BaseDir "lib\pipeline_status.ps1")
      Close-RunControl -BaseDir $g.BaseDir -RunId $g.RunId -State "stopped" -OnlyIfRunning | Out-Null
      Close-PipelineStatusForRun -BaseDir $g.BaseDir -RunId $g.RunId -State "failed" -Error "aborted" -OnlyIfRunning | Out-Null
      if (-not $g.Done) {
        $null = Write-RunSummary -BaseDir $g.BaseDir -RunId $g.RunId -StartedAt $g.StartedAt -Ok $false -Code "aborted" -Reason "脚本未走到收尾就退出（异常/强制终止）"
      }
    }
  } catch { }
} | Out-Null
function Set-Pipe([string]$current, [string]$next, [string]$state, [string]$err) {
  try {
    $script:pipe.updated_at = (Get-Date).ToString("o")
    if ($current) { $script:pipe.current_platform = $current }
    if ($next) { $script:pipe.next_platform = $next }
    if ($state) { $script:pipe.state = $state }
    if ($err) { $script:pipe.last_error = $err }
    Save-PipelineStatus -Path $script:pipePath -Status $script:pipe
    # current_platform is a platform, not a phase; startCb updates it explicitly.
  } catch { }
}
function StoppedNow {
  if (Test-GOpsStop $baseDir) { return $true }
  return (Test-RunStopRequested -BaseDir $baseDir -RunId $runId)
}

# ---- 统一收尾：所有退出路径都写一份 run_summary（含 run_id / code / 失败项）----
function Finish-Summary([string]$Code, [bool]$Ok = $false, [string]$Reason = "", [string[]]$Reasons = @(), [string[]]$Errors = @()) {
  try {
    . (Join-Path $baseDir "lib\run_summary.ps1")
    $ar = @(); if ($Reason) { $ar += $Reason }; if ($Reasons) { $ar += $Reasons }
    $null = Write-RunSummary -BaseDir $baseDir -RunId $runId -StartedAt $script:pipe.started_at -Ok $Ok -Code $Code -Reason $Reason -Reasons @($ar) -Platforms $Platforms -Errors @($Errors)
    $global:GOPS_SUMMARY.Done = $true
  } catch { Say ("run summary failed: " + $_.Exception.Message) }
}

if (Test-GOpsStop $baseDir) { Set-Pipe "stop" "" "stopped" ""; Say "stop flag -> 退出"; Finish-Summary -Code "stopped" -Ok $true -Reason "手动停止（stop.flag 存在），本轮未启动"; exit 0 }

# 0.1) 配置：只跑本轮已启用的平台
$cfg = $null
try { $cfg = Get-Content (Join-Path $baseDir "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$enabled = @{}
try {
  if ($cfg -and $cfg.platformsEnabled) {
    foreach ($p in $cfg.platformsEnabled.PSObject.Properties) { $enabled[[string]$p.Name] = [bool]$p.Value }
  }
} catch { }
$Platforms = @($Platforms | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($enabled.Count -gt 0) {
  $Platforms = @($Platforms | Where-Object { $enabled.ContainsKey($_) -and $enabled[$_] })
}
$manualExec = @("Telegram", "Facebook")
$unsupported = @($Platforms | Where-Object { $manualExec -notcontains [string]$_ })
if ($unsupported.Count -gt 0) {
  Say ("run_all 只驱动扩展执行器平台（Telegram/Facebook）；本轮收到：" + ($unsupported -join "、") + "。Reddit/Steam/WhatsApp 请用 run_daily 的专用 runner。")
  Set-Pipe "" "" "failed" "platform_no_manual_executor"
  Finish-Summary -Code "platform_no_manual_executor" -Ok $false -Reason ("不支持手动执行的平台：" + ($unsupported -join "、"))
  exit 2
}
if ($Platforms.Count -eq 0) { Set-Pipe "" "" "complete" ""; Say "没有已启用平台，退出"; Finish-Summary -Code "no_platforms" -Ok $true -Reason "没有已启用平台"; exit 0 }
$script:pipe = New-PipelineStatus -RunId $runId -Platforms $Platforms
$script:runRegistered = $false
$reg = Register-RunControl -BaseDir $baseDir -RunId $runId -Platforms $Platforms -Current ([string]$Platforms[0])
if (-not $reg.ok) { Say ("已有运行中的 run，退出：" + [string]$reg.run_id); Close-PipelineStatusForRun -BaseDir $baseDir -RunId $runId -State "stopped" -Error ("already_running: " + [string]$reg.run_id) -OnlyIfRunning | Out-Null; Finish-Summary -Code "already_running" -Ok $false -Reason ("已有运行中的 run：" + [string]$reg.run_id); exit 0 }
$script:runRegistered = $true
$env:GOPS_RUN_ID = $runId
Set-Pipe "self_check" ([string]$Platforms[0]) "running" ""

# 1) 前台体检
if (-not $SkipSelfCheck) {
  $chk = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "check.ps1") 2>&1
  $chkLast = ($chk | Select-Object -Last 1)
  Say ("check.ps1 -> " + $chkLast)
  if ($chkLast -notmatch "可以开工") {
    Set-Pipe "self_check" "" "failed" "check_failed"
    $chkFails = @($chk | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match "^\[!!\]" } | Select-Object -First 6)
    $chkReason = "自检未通过（" + @($chkFails).Count + " 项），见 reasons/errors"
    Finish-Summary -Code "check_failed" -Ok $false -Reason $chkReason -Reasons @($chkFails) -Errors @($chkFails)
    Say "自检未通过，中止（先处理红灯）"
    Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null
    exit 3
  }
}

# 2) 逐平台拓群。冷却只跳过该平台；stop 正常结束；其它启动/等待故障中止本轮。
Set-Pipe "platform_scan" "members" "running" ""
$startCb = {
  param($p)
  if (StoppedNow) { return @{ ok = $false; error = "stopped" } }
  try {
    Update-RunControlPlatform -BaseDir $baseDir -RunId $runId -Current $p | Out-Null
    Hub "POST" "/control" @{ action = "start"; platform = $p; run_id = $runId } | Out-Null
    return @{ ok = $true }
  } catch {
    $msg = [string]$_.Exception.Message
    $err = "hub_unreachable"
    $detail = $msg
    try {
      $j = $_.ErrorDetails.Message | ConvertFrom-Json
      if ($j.error) { $err = [string]$j.error }
      if ($j.detail) { $detail = [string]$j.detail }
    } catch { }
    return @{ ok = $false; error = $err; detail = $detail }
  }
}
$waitCb = {
  param($p)
  $deadline = (Get-Date).AddMinutes($WaitTimeoutMin)
  $lastPhase = ""
  while ((Get-Date) -lt $deadline) {
    if (StoppedNow) { return $false }
    if (Test-RunPlatformSkip -BaseDir $baseDir -RunId $runId -Platform $p) {
      try { Hub "POST" "/control" @{ action = "skip_platform"; run_id = $runId; platform = $p } | Out-Null } catch { }
      # Do not start the next platform until the hub has actually left this
      # round; otherwise the next start races a still-running external round.
      $sd = (Get-Date).AddSeconds(180)
      $idle = $false
      while ((Get-Date) -lt $sd) {
        try { $hh = Hub "GET" "/health" $null; if (-not $hh.running) { $idle = $true; break } } catch { }
        Start-Sleep -Seconds 2
      }
      if (-not $idle) { throw "hub did not stop after skip" }
      return "skip"
    }
    Start-Sleep -Seconds 10
    $h = Hub "GET" "/health" $null
    if ($h.phase -ne $lastPhase) { $lastPhase = $h.phase; Say ("  " + $p + " phase=" + $h.phase) }
    if (-not $h.running) { return $true }
  }
  # A wait timeout means the hub round is no longer trustworthy. Close only
  # this run (cleanup requires run_id) and surface a global failure instead of
  # starting the next platform against a still-running external round.
  try { Hub "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $runId } | Out-Null } catch { }
  throw ("platform wait timeout: " + $p)
}
$res = Invoke-PlatformSequence -Platforms $Platforms -Start $startCb -Wait $waitCb -IsStopped { StoppedNow } -IsSkipped { param($p) Test-RunPlatformSkip -BaseDir $baseDir -RunId $runId -Platform $p } -Say { param($m) Say $m }
$fail += @($res.failed)
$script:pipe.completed = [math]::Max(0, @($Platforms).Count - @($res.failed).Count)
if ($res.status -eq "stopped") {
  Set-Pipe "platform_scan" "" "stopped" ""
  Say "stop signal -> 退出"
  Finish-Summary -Code "stopped" -Ok $true -Reason "用户停止（运行中被要求停止）"
  try { Hub "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $runId } | Out-Null } catch { }
  Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null
  exit 0
}
if ($res.status -eq "global_failure") {
  Set-Pipe "platform_scan" "" "failed" ([string]$res.error)
  Say ("全局故障，中止本轮：" + [string]$res.error)
  Finish-Summary -Code "global_failure" -Ok $false -Reason ("全局故障：" + [string]$res.error) -Errors @([string]$res.error)
  try { Hub "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $runId } | Out-Null } catch { }
  Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null
  exit 4
}
Say ("--- 平台拓群结束（失败：" + $(if (@($res.failed).Count -gt 0) { @($res.failed) -join "," } else { "无" }) + "）")

# 3) 成员采样 + 人数回填
Set-Pipe "members" "steam" "running" ""
if (-not $SkipMembers) {
  if (StoppedNow) { Set-Pipe "members" "" "stopped" ""; Say "stop signal -> 跳过成员采样"; Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null; exit 0 }
  Say "--- 成员样本（按 config.memberSample 各平台独立：开关/每轮上限/预算）"
  try {
    . (Join-Path $baseDir "lib\member_run.ps1")
    $msRes = @()
    foreach ($pl in @("Telegram","Steam")) {
      $r = Invoke-MemberSampling -BaseDir $baseDir -Platform $pl -Cfg $cfg -Say { param($m) Say $m } -Stopped { StoppedNow }
      $msRes += $r
    }
    Say ("  成员样本汇总：" + (($msRes | ForEach-Object { $_.platform + " enabled=" + $_.enabled + " handled=" + $_.handled + " ok=" + $_.ok + " bad=" + $_.bad }) -join "；"))
  } catch { Say ("  成员采样异常：" + $_.Exception.Message) }

  Say "--- 人数回填（含隐藏名单）"
  $out2 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "tg_fix_counts.ps1") -IncludeHidden 2>&1
  ($out2 | Select-String "UPDATED|targets=" | Select-Object -Last 2) | ForEach-Object { Say ("  " + $_.Line) }
}

# 4) Steam 抽样 + 导入成员样本
Set-Pipe "steam" "db" "running" ""
if (-not $SkipSteam) {
  if (StoppedNow) { Set-Pipe "steam" "" "stopped" ""; Say "stop signal -> 跳过 Steam"; Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null; exit 0 }
  # Steam 全量采样已并入上面的「成员样本」阶段；此处只做导入

  Say "--- 导入成员样本"
  $out4 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "steam_to_users.ps1") 2>&1
  ($out4 | Select-String "CSV VIEW|WROTE" | Select-Object -Last 2) | ForEach-Object { Say ("  " + $_.Line) }
}

# 4.5) 同步到本地数据库
if (-not $SkipSteam) {
  Set-Pipe "db" "report" "running" ""
  if (StoppedNow) { Set-Pipe "db" "" "stopped" ""; Say "stop signal -> 跳过数据库"; Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null; exit 0 }
  Say "--- 同步到本地数据库"
  try {
    . (Join-Path $baseDir "lib\db.ps1")
    Initialize-LocalDb | Out-Null
    $dbr = Import-LocalDb -CsvPaths @((Join-Path $baseDir "data\users.csv"))
    Say ("  db rows imported = " + $dbr.imported)
  } catch { Say ("  db sync failed: " + $_.Exception.Message) }
}

# 5) 日报
Set-Pipe "report" "leads" "running" ""
$autoReport = (-not $NoReport) -or $Report
if ($autoReport) {
  if (StoppedNow) { Set-Pipe "report" "" "stopped" ""; Say "stop signal -> 跳过日报"; Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null; exit 0 }
  Say "--- 发日报"
  $out5 = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "report_all.ps1") 2>&1
  ($out5 | Select-String "webhook|合计|failed|error" | Select-Object -Last 3) | ForEach-Object { Say ("  " + $_.Line) }
}

if ($fail.Count -gt 0) { Set-Pipe "done" "" "failed" ($fail -join ","); Finish-Summary -Code "failed" -Ok $false -Reason ("失败平台：" + ($fail -join ",")) -Errors @($fail); Say ("=== run_all 结束，失败平台：" + ($fail -join ",") + " ==="); Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null; exit 4 }
Set-Pipe "leads" "" "running" ""
if (-not $SkipLeads) {
  if (StoppedNow) {
    Set-Pipe "leads" "" "stopped" ""
    Say "stop signal present, skip leads"
    Finish-Summary -Code "stopped" -Ok $true -Reason "用户停止（leads 阶段）"
    try { Hub "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $runId } | Out-Null } catch { }
    Close-RunControl -BaseDir $baseDir -RunId $runId -State "stopped" | Out-Null
    exit 0
  }
  else {
    Say "--- 线索流水线（扫描/打分/入库）"
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "leads_daily.ps1") | Out-Null
      Say "leads ok"
    } catch { Say ("leads failed: " + $_.Exception.Message) }
  }
}

Set-Pipe "" "" "complete" ""
Complete-RunControl -BaseDir $baseDir -RunId $runId | Out-Null
Finish-Summary -Code "complete" -Ok $true -Reason "正常完成"
try { Hub "POST" "/control" @{ action = "stop"; cleanup = $true; run_id = $runId } | Out-Null } catch { }
Say "=== run_all 全部完成 ==="
