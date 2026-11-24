# --- planned round entry (real run_daily entry; inert unless GOPS_PLANNED_ROUND=1) ---
if ($env:GOPS_PLANNED_ROUND -eq "1") {
  . (Join-Path $PSScriptRoot "lib\round_engine.ps1")
  . (Join-Path $PSScriptRoot "lib\platform_runners.ps1")
  $rr = $env:GOPS_ROUND_RUNNERS
  if ($rr) { . $rr; $runners = New-FakeRunners } else { $runners = New-PlatformRunners }
    $planCfg = @()
    if ($env:GOPS_ROUND_PLAN) {
      $planCfg = @($env:GOPS_ROUND_PLAN -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else {
      try {
        $cj = Get-Content (Join-Path $PSScriptRoot "config.json") -Raw | ConvertFrom-Json
        $planCfg = @($cj.platformsEnabled.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name })
      } catch { $planCfg = @() }
    }
    if (@($planCfg).Count -eq 0) { Write-Host "[round] empty plan (no GOPS_ROUND_PLAN and no config.json)"; exit 3 }
  $rid = "run_daily-" + (Get-Date -Format "yyyyMMdd-HHmmss")
  $roundRoot = if ($env:GOPS_ROUND_WORKDIR) { $env:GOPS_ROUND_WORKDIR } elseif ($env:GOPS_STATE_ROOT) { Join-Path $env:GOPS_STATE_ROOT "round" } else { Join-Path $PSScriptRoot "data\round" }
  $st = Invoke-RoundRun -WorkDir $roundRoot -Plan $planCfg -RunId $rid -Entry daily -Runners $runners
  Write-Host ("[round] state=" + $st.state + " joined=" + $st.summary.joined + " pending=" + $st.summary.pending)
  exit 0
}# run_daily.ps1 —— 计划任务入口：hub 探活 + 外部平台 worker。
# 停止运行 = 本轮停止信号（不写全局急停）；跳过平台 = 当前平台退出后继续。
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $here "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir "daily.log"

. (Join-Path $here "lib\stop.ps1")
. (Join-Path $here "lib\pipeline_status.ps1")
. (Join-Path $here "lib\worker_control.ps1")
. (Join-Path $here "lib\run_control.ps1")
. (Join-Path $here "lib\platform_cooldown.ps1")
. (Join-Path $here "lib\round_report.ps1")

function Log($m) {
  $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  " + $m
  Add-Content -Path $log -Value $line -Encoding UTF8
}

$runId = "run_daily-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + "-" + $PID
$pipePath = Get-PipelineStatusPath -BaseDir $here
$steps = @("hub", "Steam", "Reddit", "WhatsApp")
$pipe = New-PipelineStatus -RunId $runId -Platforms $steps
$script:runRegistered = $false
function Set-Pipe([string]$current, [string]$next, [string]$state, [string]$err, $completed) {
  try {
    $pipe.updated_at = (Get-Date).ToString("o")
    if ($current -ne $null) { $pipe.current_platform = $current }
    if ($next -ne $null) { $pipe.next_platform = $next }
    if ($state) { $pipe.state = $state }
    if ($err) { $pipe.last_error = $err }
    if ($completed -ne $null) { $pipe.completed = [int]$completed }
    Save-PipelineStatus -Path $pipePath -Status $pipe
    if ($script:runRegistered -and $current) { Update-RunControlPlatform -BaseDir $here -RunId $runId -Current $current | Out-Null }
  } catch { }
}
function Stop-Now([string]$where) {
  Set-Pipe $where "" "stopped" "" $null
  try {
    . (Join-Path $here "lib\run_summary.ps1")
    $rp = @($script:reportPlan)
    if (@($rp).Count -eq 0) { $rp = @($script:plats) }
    if (@($rp).Count -eq 0) { $rp = @("Facebook", "Telegram", "Reddit", "WhatsApp", "Steam") }
    $rr = @{}
    foreach ($pp in $rp) {
      if ($script:hubResults -and $script:hubResults.ContainsKey($pp)) { $rr[$pp] = $script:hubResults[$pp] }
      else { $rr[$pp] = New-PlatformResult -Platform $pp -Result "未运行" }
    }
    $rep = New-RoundReport -Plan $rp -Results $rr -StartedAt $script:pipe.started_at -EndedAt (Get-Date) -Code "stopped" -StopReason ("停在 " + $where) -LateCount ([int]$script:lateCount) -RunId $script:runId
    $null = Write-RunSummary -BaseDir $here -RunId $script:runId -StartedAt $script:pipe.started_at -Ok $false -Code "stopped" -Reason $rep.summary -Reasons @($rep.lines) -Platforms @($rp) -Extra @{ report = @($rep.lines); report_text = $rep.text; platform_results = $rep.results; late_receipts = [int]$script:lateCount }
  } catch { Log ("stop summary failed: " + $_.Exception.Message) }
  Close-RunControl -BaseDir $here -RunId $runId -State "stopped" | Out-Null
  Log ("stop signal -> 停在 " + $where)
  exit 0
}
function Stop-Requested {
  if (Test-GOpsStop $here) { return $true }
  return (Test-RunStopRequested -BaseDir $here -RunId $runId)
}
function Skip-Requested([string]$platform) {
  return (Test-RunPlatformSkip -BaseDir $here -RunId $runId -Platform $platform)
}
function Wait-Signal([string]$platform, [int]$seconds) {
  return (Wait-RunSignal -BaseDir $here -RunId $runId -Platform $platform -Seconds $seconds -SleepMs 1000)
}

Set-Pipe "hub" "Steam" "running" "" 0
if (Test-GOpsStop $here) { Stop-Now "startup" }
$reg = Register-RunControl -BaseDir $here -RunId $runId -Platforms $steps -Current "hub"
if (-not $reg.ok) {
  Log ("skip run: " + $reg.reason + " existing=" + [string]$reg.run_id)
  exit 0
}
$script:runRegistered = $true
$env:GOPS_RUN_ID = $runId
Log ("run " + $runId + " start")

$cfg = $null
try { $cfg = Get-Content (Join-Path $here "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$plats = @()
try {
  if ($cfg -and $cfg.platforms) {
    foreach ($p in @($cfg.platforms)) {
      $enabled = $true
      try { if ($cfg.platformsEnabled -and $cfg.platformsEnabled.PSObject.Properties.Name -contains $p) { $enabled = [bool]$cfg.platformsEnabled.$p } } catch { }
      if ($enabled) { $plats += [string]$p }
    }
  }
} catch { }

$alive = $false
if ($env:GOPS_OFFLINE -ne "1") {
  try {
    Invoke-RestMethod "http://127.0.0.1:8787/health" -TimeoutSec 4 | Out-Null
    $alive = $true
    Log "hub alive"
  } catch {
    Log "hub not running, starting"
  }
  if (-not $alive) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
      "-File", (Join-Path $here "hub.ps1")
    ) -WindowStyle Hidden
    $sig = Wait-Signal "hub" 10
    if ($sig -eq "stop" -or (Stop-Requested)) { Stop-Now "hub-start" }
  }
} else {
  Log "hub probe skipped (offline test)"
}

# 1) hub 平台（仅 Facebook/Telegram/Reddit；每平台独立一轮，逐平台等待完成）
Set-Pipe "hub" "Steam" "running" "" 0
$env:GOPS_PLATFORM = "hub"
$hubPlats = @("Facebook", "Telegram", "Reddit")
$hubResults = @{}
$lateCount = 0
$stateReport = ""
$reportPlan = @($plats)
if (@($reportPlan).Count -eq 0) { $reportPlan = @("Facebook", "Telegram", "Reddit", "WhatsApp", "Steam") }
$finalCode = "complete"
$stopReason = ""
foreach ($p in $hubPlats) {
  if (Stop-Requested) { $finalCode = "stopped"; $stopReason = "收到本轮停止信号"; break }
  if (Skip-Requested "hub") { Log "skip platform hub"; break }
  $q = 0
  try { if ($cfg.quotas.PSObject.Properties.Name -contains $p) { $q = [int]$cfg.quotas.$p } } catch { }
  if ($q -le 0) { Log ("skip " + $p + " (quota 0)"); continue }
  $hubState = $null
  try {
    $body = @{ action = "start"; platform = $p; run_id = $runId } | ConvertTo-Json -Compress
    Invoke-RestMethod "http://127.0.0.1:8787/control" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15 | Out-Null
    Log ("started " + $p + " quota=" + $q)
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
      if (Stop-Requested) { break }
      try { $hubState = Invoke-RestMethod "http://127.0.0.1:8787/state" -TimeoutSec 5 } catch { Start-Sleep -Seconds 2; continue }
      if ([string]$hubState.run_id -and [string]$hubState.run_id -ne $runId) { Log ("hub run mismatch: " + [string]$hubState.run_id); break }
      if (-not [bool]$hubState.running) { break }
      Start-Sleep -Seconds 2
    }
  } catch { Log ("start failed: " + $_.Exception.Message) }
  if ($hubState) {
    $ps = $null
    try { $ps = $hubState.platformStats.$p } catch { }
    if (-not $ps) { $ps = New-PlatformResult -Platform $p -Result "完成" }
    if ([string]$hubState.report_text) { $stateReport = [string]$hubState.report_text }
    try { $lateCount = [Math]::Max($lateCount, [int]$hubState.late_receipts) } catch { }
    if ([string]$ps.result -eq "未运行" -or [string]$ps.result -eq "进行中") { $ps.result = "完成" }
    if ([string]$ps.result -eq "部分完成（已停止新派发）") { $finalCode = "partial_complete" }
    $hubResults[$p] = $ps
    Log ("hub " + $p + " done result=" + $ps.result + " joined=" + $ps.joined + " existing=" + $ps.existing + " unconfirmed=" + $ps.unconfirmed + " failed=" + $ps.failed)
  } else {
    $hubResults[$p] = New-PlatformResult -Platform $p -Result "失败" -Reason "hub 未返回状态"
    $finalCode = "partial_complete"
  }
  if (Stop-Requested) { $finalCode = "stopped"; $stopReason = "收到本轮停止信号"; break }
  if (Skip-Requested "hub") { Log "skip platform hub"; break }
}
Set-Pipe "Steam" "Reddit" "running" "" 1

# 2) Steam
$env:GOPS_PLATFORM = "Steam"
$steamOn = $false
try { $steamOn = [bool]$cfg.behaviors.Steam.join } catch { }
if ($steamOn) {
  $sq = Join-Path $here "data\steam_queue.txt"
  $sn = 0
  try { $sn = [int]$cfg.quotas.Steam } catch { }
  if ((Test-Path $sq) -and $sn -gt 0) {
    $targets = @(Get-Content $sq -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith("#") } | Select-Object -First $sn)
    foreach ($g in $targets) {
      if (Stop-Requested) { Stop-Now "Steam" }
      if (Skip-Requested "Steam") { Log "skip platform Steam"; break }
      Set-Pipe "Steam" "Reddit" "running" "" 1
      Log ("steam join " + $g)
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "steam_join.ps1") -Group $g *>&1 | Out-File -FilePath $log -Append -Encoding UTF8
      if (Stop-Requested) { Stop-Now "Steam" }
      if (Skip-Requested "Steam") { Log "skip platform Steam"; break }
      $sig = Wait-Signal "Steam" 600
      if ($sig -eq "stop" -or (Stop-Requested)) { Stop-Now "Steam" }
      if ($sig -eq "skip") { Log "skip platform Steam"; break }
    }
  }
}
# 2.5) 成员样本（与拓群解耦；按 config.memberSample 各平台独立开关/上限/预算）
if ($cfg.memberSample) {
  if (Stop-Requested) { Stop-Now "MemberSample" }
  . (Join-Path $here "lib\member_run.ps1")
  try {
    foreach ($pl in @("Telegram","Steam")) {
      $null = Invoke-MemberSampling -BaseDir $here -Platform $pl -Cfg $cfg -Say { param($m) Log $m } -Stopped { Stop-Requested }
    }
  } catch { Log ("member sample error: " + $_.Exception.Message) }
}
Set-Pipe "Reddit" "WhatsApp" "running" "" 2

# 3) Reddit
$env:GOPS_PLATFORM = "Reddit"
$redditOn = $false
try { $redditOn = [bool]$cfg.behaviors.Reddit.discover } catch { }
if ($redditOn) {
  if (Stop-Requested) { Stop-Now "Reddit" }
  $rn = 0
  try { $rn = [int]$cfg.quotas.Reddit } catch { }
  if ($rn -gt 0 -and -not (Skip-Requested "Reddit")) {
    Log ("reddit run maxSubs=" + $rn)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "rd_run.ps1") -MaxSubs $rn *>&1 | Out-File -FilePath $log -Append -Encoding UTF8
    if (Stop-Requested) { Stop-Now "Reddit" }
  } elseif (Skip-Requested "Reddit") {
    Log "skip platform Reddit"
  }
}
Set-Pipe "WhatsApp" "" "running" "" 3

# 4) WhatsApp -- only through the controlled one-shot verifier.
$env:GOPS_PLATFORM = "WhatsApp"
$waOn = $false
try { $waOn = [bool]$cfg.behaviors.WhatsApp.join } catch { }
if ($waOn) {
  $wn = 0
  try { $wn = [int]$cfg.quotas.WhatsApp } catch { }
  $waPlan = $null
  try { if ($cfg.wa -and $cfg.wa.PSObject.Properties.Name -contains "one_shot") { $waPlan = $cfg.wa.one_shot } } catch { }
  $targetCode = ""
  $publisher = ""
  $whitelist = ""
  $allowJoin = $false
  if ($waPlan) {
    try { $targetCode = [string]$waPlan.target_code } catch { }
    try { $publisher = [string]$waPlan.publisher } catch { }
    try { $whitelist = [string]$waPlan.publisher_whitelist } catch { }
    try { $allowJoin = [bool]$waPlan.allow_join } catch { }
  }
  if (-not $targetCode -or -not $publisher) {
    Log "whatsapp skipped: no explicit wa.one_shot target (daily never auto-clicks)"
  } elseif ($wn -le 0) {
    Log "skip WhatsApp (quota 0)"
  } else {
    $cooldownPath = Get-PlatformCooldownPath -BaseDir $here
    $cd = Get-PlatformCooldown -Path $cooldownPath -Platform "WhatsApp"
    if ($cd) {
      Log ("skip WhatsApp (cooldown " + [string]$cd.remaining_sec + "s: " + [string]$cd.reason + ")")
    } else {
      if (-not $whitelist) { $whitelist = $publisher + "|" + $targetCode }
      $waArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $here "wa_verify.ps1"), "-OneShot", "-TargetCode", $targetCode, "-Publisher", $publisher, "-PublisherWhitelist", $whitelist, "-MaxActions", "1")
      if ($allowJoin) { $waArgs += "-AllowJoin" } else { $waArgs += "-DryRun" }
      Log ("whatsapp one-shot " + $targetCode + " preview=" + [string](-not $allowJoin))
      & powershell.exe @waArgs *>&1 | Out-File -FilePath $log -Append -Encoding UTF8
      $waExit = $LASTEXITCODE
      Log ("whatsapp one-shot exit=" + $waExit)
      if (Stop-Requested) { Stop-Now "WhatsApp" }
      if (Skip-Requested "WhatsApp") { Log "skip platform WhatsApp"; }
      elseif ($waExit -eq 4) { Stop-Now "WhatsApp" }
      elseif ($waExit -eq 2) {
        Log "whatsapp terminal/precondition; continue to next platform"
      } elseif ($waExit -ne 0) {
        Set-PlatformCooldown -Path $cooldownPath -Platform "WhatsApp" -Minutes 30 -Reason "wa_one_shot_failed" | Out-Null
        Log "whatsapp one-shot failed; cooldown WA only, continue to next platform"
      }
    }
  }
}

if (Stop-Requested) { $finalCode = "stopped"; $stopReason = "收到本轮停止信号" }
Complete-RunControl -BaseDir $here -RunId $runId | Out-Null
Set-Pipe "" "" $(if ($finalCode -eq "complete") { "complete" } else { $finalCode }) "" $steps.Count
try {
  . (Join-Path $here "lib\run_summary.ps1")
  $rsReasons = @(Get-RunReasonFromLog -LogPath $log -Tail 600)
  $rsOk = ($finalCode -eq "complete") -and ($rsReasons -notcontains "采样有失败目标")
  $reportResults = @{}
  foreach ($p in $reportPlan) {
    if ($hubResults.ContainsKey($p)) { $reportResults[$p] = $hubResults[$p] }
    else { $reportResults[$p] = New-PlatformResult -Platform $p -Result "完成（外部阶段未统计）" }
  }
  $rep = New-RoundReport -Plan $reportPlan -Results $reportResults -StartedAt $pipe.started_at -EndedAt (Get-Date) -Code $finalCode -StopReason $stopReason -LateCount $lateCount -RunId $runId
  $null = Write-RunSummary -BaseDir $here -RunId $runId -StartedAt $pipe.started_at -Ok $rsOk -Code $finalCode -Reason $rep.summary -Reasons @($rep.lines) -Platforms @($reportPlan) -Extra @{ report = @($rep.lines); report_text = $rep.text; platform_results = $rep.results; late_receipts = [int]$lateCount }
} catch { Log ("run summary failed: " + $_.Exception.Message) }
Log "run_daily complete"
exit 0
