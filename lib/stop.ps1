function Get-GOpsStopFile([string]$BaseDir) {
  if ($env:GOPS_STOP_FILE) { return $env:GOPS_STOP_FILE }
  if ($env:GOPS_STATE_ROOT) { return (Join-Path $env:GOPS_STATE_ROOT "stop.flag") }
  if (-not $BaseDir) { $BaseDir = (Split-Path -Parent $PSScriptRoot) }
  return (Join-Path $BaseDir "data\stop.flag")
}
function Test-GOpsStop([string]$BaseDir) {
  return (Test-Path (Get-GOpsStopFile $BaseDir))
}
function Set-GOpsStop([string]$BaseDir, [string]$Why) {
  $f = Get-GOpsStopFile $BaseDir
  $d = Split-Path -Parent $f
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  $txt = (Get-Date).ToString("s") + " " + $Why
  [System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false)))
  return $f
}
function Clear-GOpsStop([string]$BaseDir) {
  $f = Get-GOpsStopFile $BaseDir
  if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

function Get-GOpsStopInfo([string]$BaseDir) {
  $f = Get-GOpsStopFile $BaseDir
  $info = @{ present = $false; known = $false; text = ""; meta = $null; path = $f; reason = "absent" }
  if (-not (Test-Path $f)) { return $info }
  $info.present = $true
  try { $info.text = ([System.IO.File]::ReadAllText($f)).Trim() } catch { }
  $metaPath = $f + ".meta.json"
  if (Test-Path $metaPath) {
    try { $info.meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  if ($info.meta -and [string]$info.meta.source -eq "hub_stop") {
    $info.known = $true
    $info.reason = "hub_stop_meta"
    return $info
  }
  # Legacy hub stop text written by Set-GOpsStop("hub stop HH:mm:ss").
  if ($info.text -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\s+hub stop\s+\d{2}:\d{2}:\d{2}$') {
    $info.known = $true
    $info.reason = "hub_stop_legacy"
    return $info
  }
  $info.reason = "unknown_stop_marker"
  return $info
}

function Set-GOpsStopWithMeta([string]$BaseDir, [string]$Why, [string]$Source, [string]$RunId) {
  $f = Set-GOpsStop $BaseDir $Why
  try {
    $meta = @{ source = $Source; run_id = [string]$RunId; at = (Get-Date).ToString("o") }
    [System.IO.File]::WriteAllText($f + ".meta.json", ($meta | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
  return $f
}

function Clear-KnownHubStop([string]$BaseDir) {
  $info = Get-GOpsStopInfo $BaseDir
  if (-not $info.present) { return @{ ok = $true; error = "absent"; reason = "absent" } }
  if (-not $info.known) { return @{ ok = $false; error = "unknown_stop_marker"; reason = "unknown_stop_marker" } }
  $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
  $backup = $info.path + ".bak." + $stamp + ".txt"
  try {
    Copy-Item -Path $info.path -Destination $backup -Force
    $metaPath = $info.path + ".meta.json"
    if (Test-Path $metaPath) { Copy-Item -Path $metaPath -Destination ($backup + ".meta.json") -Force }
    Remove-Item -Path $info.path -Force
    if (Test-Path $metaPath) { Remove-Item -Path $metaPath -Force }
  } catch {
    return @{ ok = $false; error = "clear_failed"; reason = "clear_failed"; detail = $_.Exception.Message }
  }
  return @{ ok = $true; error = ""; backup = $backup; reason = "cleared" }
}
