# run_summary.ps1 - 每轮结束的「人话总结」：写 data\run_summary.json，供看板/侧边栏显示
# 目的：跑完（或被跳过/限流/中止）时，界面上必须有一句能看懂的原因，而不是只显示「空闲」。

function Get-RunSummaryPath {
    param([string]$BaseDir)
  if ($env:GOPS_STATE_ROOT) { return (Join-Path $env:GOPS_STATE_ROOT "run_summary.json") }
    if (-not $BaseDir) { $BaseDir = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $BaseDir "data\run_summary.json")
}

function Get-CountLines {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return 0 }
    try { return ([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)).Count } catch { return 0 }
}

function Get-MemberStateCounts {
    param([string]$BaseDir, [string]$Platform)
    $p = Join-Path $BaseDir ("data\members\" + $Platform.ToLower() + ".json")
    if (-not (Test-Path $p)) { return $null }
    try {
        $j = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $t = $j.targets
        if (-not $t) { return $null }
        $done = 0; $pending = 0; $bad = 0; $limited = 0
        foreach ($k in $t.PSObject.Properties.Name) {
            $s = [string]$t.$k.status
            switch ($s) {
                "done" { $done++ }
                "" { $pending++ }
                "pending" { $pending++ }
                "rate_limited" { $limited++ }
                "dead" { $bad++ }
                "permission_denied" { $bad++ }
                default { $pending++ }
            }
        }
        return @{ done = $done; pending = $pending; dead = $bad; rate_limited = $limited }
    } catch { return $null }
}

# 从日志尾部提炼「为什么停/为什么没结果」，只取最后若干条关键行
function Get-RunReasonFromLog {
    param([string]$LogPath, [int]$Tail = 400)
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return @() }
    $lines = @()
    try { $lines = Get-Content $LogPath -Tail $Tail -Encoding UTF8 } catch { return @() }
    $hits = @()
    foreach ($ln in $lines) {
        $s = [string]$ln
        if ($s -match "429|rate_limited|限流") { $hits += "Steam 采样被限流（429）" }
        elseif ($s -match "whatsapp skipped") { $hits += "WhatsApp 按设计跳过（没有指定 one-shot 目标）" }
        elseif ($s -match "quota 0") { $hits += "某平台配额为 0，跳过" }
        elseif ($s -match "cooldown") { $hits += "平台冷却中，跳过" }
        elseif ($s -match "stop signal|stop.flag|急停") { $hits += "收到停止信号" }
        elseif ($s -match "RESULT: failed|error=") { $hits += "采样有失败目标" }
        elseif ($s -match "skip platform|skipped") { }
    }
    return ($hits | Select-Object -Unique)
}

function Write-RunSummary {
    param(
        [string]$BaseDir,
        [string]$RunId,
        [string]$StartedAt,
        [bool]$Ok = $true,
        [string]$Code = "complete",
        [string]$Reason = "",
        [string[]]$Reasons = @(),
        [string[]]$Platforms = @(),
        [string[]]$Errors = @(),
        [hashtable]$Extra = @{},
        [switch]$Force
    )
    if (-not $BaseDir) { $BaseDir = Split-Path -Parent $PSScriptRoot }
    $path = Get-RunSummaryPath -BaseDir $BaseDir
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $prev = $null
    try { if (Test-Path $path) { $prev = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } } catch { }

    $now = Get-Date
    $startedDt = $null
    try { if ($StartedAt) { $startedDt = [datetime]$StartedAt } } catch { }
    $mins = $null
    if ($startedDt) { $mins = [int][math]::Round(($now - $startedDt).TotalMinutes, 0) }

    # 旧轮不得覆盖新轮：现有摘要的开始时间晚于本次，则跳过（除非 -Force）
    if (-not $Force -and $prev -and $startedDt) {
        $prevStart = $null
        try { if ($prev.started_at) { $prevStart = [datetime]$prev.started_at } } catch { }
        if ($prevStart -and $prevStart -gt $startedDt) {
            Write-Host ("[run_summary] skip stale write: prev=" + $prevStart.ToString("s") + " > this=" + $startedDt.ToString("s"))
            return $path
        }
    }

    $usersRows = Get-CountLines -Path (Join-Path $BaseDir "data\users.csv")
    $steamRows = Get-CountLines -Path (Join-Path $BaseDir "data\steam_users.csv")
    $tg = Get-MemberStateCounts -BaseDir $BaseDir -Platform "telegram"
    $stm = Get-MemberStateCounts -BaseDir $BaseDir -Platform "steam"

    $dlUsers = 0; $dlSteam = 0
    if ($prev) {
        try { $dlUsers = $usersRows - [int]$prev.counts.users_rows } catch { }
        try { $dlSteam = $steamRows - [int]$prev.counts.steam_users_rows } catch { }
    }

    $allReasons = @()
    if ($Reason) { $allReasons += $Reason }
    if ($Reasons) { $allReasons += $Reasons }
    $allReasons = @($allReasons | Where-Object { $_ } | Select-Object -Unique)
    $reasonText = ($allReasons -join "；")
    if (-not $reasonText) { $reasonText = if ($Ok) { "正常完成" } else { "未说明原因（建议查看 logs）" } }

    $obj = [ordered]@{
        run_id     = $RunId
        started_at = if ($StartedAt) { $StartedAt } else { $null }
        ended_at   = $now.ToString("o")
        duration_min = $mins
        ok         = $Ok
        code       = $Code
        reason     = $reasonText
        reasons    = @($allReasons)
        platforms  = @($Platforms)
        members    = [ordered]@{ telegram = $tg; steam = $stm }
        counts     = [ordered]@{ users_rows = $usersRows; steam_users_rows = $steamRows }
        deltas     = [ordered]@{ users_rows = $dlUsers; steam_users_rows = $dlSteam }
        errors     = @($Errors | Where-Object { $_ } | Select-Object -First 10)
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }

    $json = $obj | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $obj
}

function Get-RunSummary {
    param([string]$BaseDir)
    if (-not $BaseDir) { $BaseDir = Split-Path -Parent $PSScriptRoot }
    $path = Get-RunSummaryPath -BaseDir $BaseDir
    if (-not (Test-Path $path)) { return $null }
    try { return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
