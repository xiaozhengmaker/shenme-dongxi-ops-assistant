# pipeline_status.ps1 -- whole-pipeline status file for the side panel.
# This is a local evidence file written by run_all.ps1. A missing or invalid
# file must be reported as unknown; hub phase "done" is never a whole-run result.

function Get-PipelineStatusPath {
  param([string]$BaseDir)
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
  param([string]$RunId, [string[]]$Platforms, [datetime]$Now = (Get-Date))
  $list = @($Platforms | Where-Object { $_ })
  $first = if ($list.Count -gt 0) { [string]$list[0] } else { "" }
  $second = if ($list.Count -gt 1) { [string]$list[1] } else { "" }
  return @{
    run_id = [string]$RunId
    state = "running"
    started_at = $Now.ToString("o")
    updated_at = $Now.ToString("o")
    total = $list.Count
    completed = 0
    current_platform = $first
    next_platform = $second
    platforms = @($list)
    last_error = ""
  }
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
