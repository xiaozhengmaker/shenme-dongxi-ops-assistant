# pipeline_status.ps1 -- whole-pipeline status file for the side panel.
# This is a local evidence file written by run_all.ps1. A missing or invalid
# file must be reported as unknown; hub phase "done" is never a whole-run result.

function Get-PipelineStatusPath {
  param([string]$BaseDir)
  if ($env:GOPS_STATE_ROOT) { return (Join-Path $env:GOPS_STATE_ROOT "pipeline_status.json") }
  if ($env:GOPS_PIPELINE_STATUS_FILE) { return [string]$env:GOPS_PIPELINE_STATUS_FILE }
  $root = if ($BaseDir) { $BaseDir } else { Split-Path -Parent $PSScriptRoot }
  return (Join-Path $root "data\pipeline_status.json")
}

function Read-PipelineStatus {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path $Path)) { return $null }
  try {
    $o = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $o -or -not $o.state) { return $null }
    return $o
  } catch { return $null }
}

function Save-PipelineStatus {
  param([string]$Path, $Status)
  if (-not $Path) { throw "pipeline status path required" }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = $Status | ConvertTo-Json -Depth 8 -Compress
  $tmp = $Path + ".tmp"
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function New-PipelineStatus {
  param([string]$RunId, [string[]]$Platforms, [datetime]$Now = (Get-Date), [string[]]$Phases = @(), [int]$Total = -1)
  $list = @($Platforms | Where-Object { $_ })
  $phaseList = @($Phases | Where-Object { $_ })
  $first = if ($list.Count -gt 0) { [string]$list[0] } else { "" }
  $second = if ($list.Count -gt 1) { [string]$list[1] } else { "" }
  $totalCount = if ($Total -ge 0) { [int]$Total } else { $list.Count }
  return @{
    run_id = [string]$RunId
    state = "running"
    started_at = $Now.ToString("o")
    updated_at = $Now.ToString("o")
    total = $totalCount
    completed = 0
    current_platform = $first
    next_platform = $second
    platforms = @($list)
    phases = @($phaseList)
    last_error = ""
  }
}

function Close-PipelineStatusForRun {
  # Close only the matching run's still-running pipeline record. This is the
  # owner-side cleanup used by hub recovery and by the run_all/run_daily exit
  # handlers, so an old run can never overwrite a newer run's status file.
  param([string]$BaseDir, [string]$RunId, [string]$State = "stopped", [string]$Error = "", [switch]$OnlyIfRunning)
  try {
    if (-not $RunId) { return $false }
    $path = Get-PipelineStatusPath -BaseDir $BaseDir
    $o = Read-PipelineStatus -Path $path
    if (-not $o -or [string]$o.run_id -ne $RunId) { return $false }
    if ($OnlyIfRunning -and [string]$o.state -ne "running") { return $false }
    $o.state = $State
    $o.updated_at = (Get-Date).ToString("o")
    if ($Error) { $o.last_error = $Error }
    Save-PipelineStatus -Path $path -Status $o
    return $true
  } catch { return $false }
}

function Get-PipelineStatusView {
  param([string]$BaseDir)
  $path = Get-PipelineStatusPath -BaseDir $BaseDir
  if (-not (Test-Path $path)) {
    return [pscustomobject]@{ state = "unknown"; reason = "no_pipeline_evidence" }
  }
  $o = Read-PipelineStatus -Path $path
  if (-not $o) {
    return [pscustomobject]@{ state = "unknown"; reason = "pipeline_status_invalid" }
  }
  return $o
}


function Sync-StaleRunState {
  # In-memory hub state says "running" but the on-disk pipeline evidence says the
  # whole run already ended. External scripts (scheduled run_daily/run_all) never
  # call back into the hub, so reset the stale memory here.
  param([string]$BaseDir, $State, [int]$GraceSec = 45)
  try {
    if (-not $State) { return $false }
    if (-not $State.running) { return $false }
    $view = Get-PipelineStatusView -BaseDir $BaseDir
    $st = [string]$view.state
    if ($st -ne "complete" -and $st -ne "failed" -and $st -ne "stopped") { return $false }
    $upd = $null
    try { if ($view.updated_at) { $upd = [datetime]::Parse([string]$view.updated_at) } } catch { }
    if ($upd -and ((Get-Date) - $upd).TotalSeconds -lt $GraceSec) { return $false }
      # 只接受「在本轮开始之后才结束」的整轮证据；更早的完成记录属于上一轮
      # （例如计划任务 10:00 那一轮），不能用来证明 hub 当前这轮已结束。
      $startedLocal = $null
      try { if ($State.started) { $startedLocal = [datetime]$State.started } } catch { }
      if ($upd -and $startedLocal -and $upd -le $startedLocal) { return $false }
    $State.running = $false
    $State.phase = "idle"
    $State.task = ""
    $State.activePlatform = ""
    $State.activeAt = ""
    $State.current = "准备开始"
    return $true
  } catch { return $false }
}
