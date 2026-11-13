function Get-GOpsStopFile([string]$BaseDir) {
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
