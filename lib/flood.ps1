# lib/flood.ps1 -- persistent rate-limit breakpoint (shared by resolve entry points)
$script:FloodFile = Join-Path (Split-Path -Parent $PSScriptRoot) "data\flood_state.json"

function Get-FloodState {
  if (-not (Test-Path $script:FloodFile)) { return $null }
  try { return (Get-Content $script:FloodFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-FloodState($obj) {
  $dir = Split-Path -Parent $script:FloodFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($script:FloodFile, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FloodDeadline([string]$platform) {
  $s = Get-FloodState
  if (-not $s -or -not $s.$platform) { return $null }
  try { return [datetime]::Parse([string]$s.$platform.retry_not_before, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function Test-FloodBlocked([string]$platform) {
  $d = Get-FloodDeadline $platform
  if (-not $d) { return $false }
  return ((Get-Date) -lt $d)
}

function Set-FloodBlocked([string]$platform, [int]$waitSec, [string]$trigger, [string[]]$pending) {
  $now = Get-Date
  $deadline = $now.AddSeconds($waitSec)
  $old = Get-FloodState
  $prev = $null
  if ($old -and $old.$platform) { $prev = $old.$platform }
  if ($prev) {
    try { $pd = [datetime]::Parse([string]$prev.retry_not_before, $null, [System.Globalization.DateTimeStyles]::RoundtripKind); if ($pd -gt $deadline) { $deadline = $pd } } catch { }
  }
  $obj = @{}
  if ($old) { foreach ($p in $old.PSObject.Properties) { $obj[$p.Name] = $p.Value } }
  $obj[$platform] = @{
    retry_not_before = $deadline.ToString("o")
    wait_sec         = $waitSec
    trigger          = $trigger
    first_seen_at    = $(if ($prev -and $prev.first_seen_at) { $prev.first_seen_at } else { $now.ToString("s") })
    retry_due        = $trigger
    pending_count    = @($pending).Count
    pending          = @($pending)
  }
  Save-FloodState $obj
  return $deadline
}

function Clear-FloodState([string]$platform) {
  $old = Get-FloodState
  if (-not $old) { return }
  $obj = @{}
  foreach ($p in $old.PSObject.Properties) { if ($p.Name -ne $platform) { $obj[$p.Name] = $p.Value } }
  Save-FloodState $obj
}
