# worker_control.ps1 -- external worker persistent stop checks.
# This module intentionally does not enumerate or hide terminal windows:
# a Windows Terminal window may be shared with the user. For a console-free
# start use run_hub_hidden.vbs (or a scheduled task set to "Run whether user
# is logged on or not").

function Get-WorkerStopFlagPath([string]$BaseDir) {
  if (-not $BaseDir) { $BaseDir = (Split-Path -Parent $PSScriptRoot) }
  return (Join-Path $BaseDir "data\stop.flag")
}

function Wait-WorkerStopFlag([string]$BaseDir, [int]$Seconds = 600, [int]$SleepMs = 1000) {
  $p = Get-WorkerStopFlagPath -BaseDir $BaseDir
  $deadline = (Get-Date).AddSeconds([math]::Max(0, $Seconds))
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $p) { return $true }
    Start-Sleep -Milliseconds ([math]::Max(50, $SleepMs))
  }
  return (Test-Path -LiteralPath $p)
}
