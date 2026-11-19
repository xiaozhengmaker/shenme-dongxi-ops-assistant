# platform_cooldown.ps1 -- per-platform cooldown persisted next to hub data.
# Pure helpers are command-line/testable; no network and no task dispatch.

function Get-PlatformCooldownPath([string]$BaseDir) {
  if ($env:GOPS_PLATFORM_COOLDOWN_FILE) { return [string]$env:GOPS_PLATFORM_COOLDOWN_FILE }
  if (-not $BaseDir) { $BaseDir = Split-Path -Parent $PSScriptRoot }
  return (Join-Path $BaseDir "data\platform_cooldown.json")
}

function Read-PlatformCooldownState([string]$Path) {
  $out = @{}
  try {
    if ($Path -and (Test-Path -LiteralPath $Path)) {
      $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
      if ($raw -and $raw.Trim()) {
        $obj = $raw | ConvertFrom-Json
        if ($obj) {
          foreach ($p in $obj.PSObject.Properties) { $out[[string]$p.Name] = $p.Value }
        }
      }
    }
  } catch { $out = @{} }
  return $out
}

function Save-PlatformCooldownState([string]$Path, $State) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = $State | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-PlatformCooldown([string]$Path, [string]$Platform, [datetime]$Now = (Get-Date)) {
  if (-not $Platform) { return $null }
  $state = Read-PlatformCooldownState $Path
  $key = $null
  foreach ($k in $state.Keys) { if ([string]$k -ieq $Platform) { $key = $k; break } }
  if (-not $key) { return $null }
  $entry = $state[$key]
  $until = [datetime]::MinValue
  $rawUntil = [string]$entry.until
  if (-not $rawUntil) { return $null }
  $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
  if (-not [datetime]::TryParse($rawUntil, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$until)) { return $null }
  if ($Now -lt $until) {
    return [pscustomobject]@{
      platform     = [string]$key
      until        = $until
      remaining_sec = [int][math]::Ceiling(($until - $Now).TotalSeconds)
      reason       = [string]$entry.reason
    }
  }
  return $null
}

function Set-PlatformCooldown([string]$Path, [string]$Platform, [int]$Minutes = 30, [string]$Reason = "collector_stalled", [datetime]$Now = (Get-Date)) {
  if (-not $Platform) { return $null }
  if ($Minutes -lt 1) { $Minutes = 1 }
  $state = Read-PlatformCooldownState $Path
  $key = $null
  foreach ($k in $state.Keys) { if ([string]$k -ieq $Platform) { $key = $k; break } }
  if (-not $key) { $key = $Platform }
  $until = $Now.AddMinutes($Minutes)
  $state[$key] = [pscustomobject]@{
    until  = $until.ToString("o")
    reason = [string]$Reason
    set_at = $Now.ToString("o")
  }
  Save-PlatformCooldownState $Path $state
  return (Get-PlatformCooldown -Path $Path -Platform $key -Now $Now)
}

function Clear-PlatformCooldown([string]$Path, [string]$Platform) {
  if (-not $Platform) { return }
  $state = Read-PlatformCooldownState $Path
  $keys = @($state.Keys)
  foreach ($k in $keys) { if ([string]$k -ieq $Platform) { $state.Remove($k) } }
  Save-PlatformCooldownState $Path $state
}

function Get-PlatformCooldownSnapshot([string]$Path, [datetime]$Now = (Get-Date)) {
  # Active cooldowns only, as a hashtable keyed by platform for /api/live.
  $out = [ordered]@{}
  $state = Read-PlatformCooldownState $Path
  $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
  foreach ($k in @($state.Keys)) {
    $entry = $state[$k]
    $rawUntil = [string]$entry.until
    $until = [datetime]::MinValue
    if (-not $rawUntil) { continue }
    if (-not [datetime]::TryParse($rawUntil, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$until)) { continue }
    if ($Now -lt $until) {
      $out[[string]$k] = [pscustomobject]@{
        until         = $until.ToString("o")
        remaining_sec = [int][math]::Ceiling(($until - $Now).TotalSeconds)
        reason        = [string]$entry.reason
        set_at        = [string]$entry.set_at
      }
    }
  }
  return $out
}

function Get-PlatformStartDecision([string]$Platform, [bool]$StopFlag, $Cooldown, [datetime]$Now = (Get-Date)) {
  if ($StopFlag) {
    return [pscustomobject]@{ allow = $false; reason = "stopped"; platform = $Platform; until = $null; remaining_sec = 0 }
  }
  if ($Cooldown) {
    $until = $Cooldown.until
    $rem = 0
    if ($until) { $rem = [int][math]::Ceiling((([datetime]$until) - $Now).TotalSeconds) }
    return [pscustomobject]@{ allow = $false; reason = "cooldown"; platform = $Platform; until = $until; remaining_sec = $rem }
  }
  return [pscustomobject]@{ allow = $true; reason = "allowed"; platform = $Platform; until = $null; remaining_sec = 0 }
}
